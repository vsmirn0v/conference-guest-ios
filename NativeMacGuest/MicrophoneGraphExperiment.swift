#if DEBUG
import AudioToolbox
import AVFoundation
import Darwin
import Foundation

/// Explicit feasibility probe. No peer, routing changes, recording, or publication.
final class NativeMicrophoneGraphExperiment: @unchecked Sendable {
    private static var owner: NativeMicrophoneGraphExperiment?
    private let queue = DispatchQueue(label: "startup.microphone-graph", qos: .userInitiated)
    private let eventLock = NSLock(), stateLock = NSLock()
    private var activeStage = "queued", expired = false
    private var watchdog: DispatchSourceTimer?
    private var old: AVAudioEngine?, replacement: AVAudioEngine?
    private var oldSource: AVAudioSourceNode?, newSource: AVAudioSourceNode?
    private var inputMixer: AVAudioMixerNode?, inputSink: AVAudioSinkNode?, tappedInput: AVAudioInputNode?
    private var tapInstalled = false, oldExpectedRunning = true
    private var candidateFormat: AVAudioFormat?, oldSampleRate = 0.0
    private let oldMeter = Meter(), inputMeter = Meter(), silentMeter = Meter(), adoptedMeter = Meter()
    private var stoppedArm: Bool { ProcessInfo.processInfo.environment["ROCK_MIC_GRAPH_STOPPED"] == "1" }
    private weak var retiredSource: AVAudioSourceNode?, retiredMixer: AVAudioMixerNode?, retiredSink: AVAudioSinkNode?

    static func startIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["ROCK_MIC_GRAPH"] == "1" else { return false }
        let value = Self(); owner = value
        value.queue.async { value.run() }
        return true
    }
    private func emit(_ event: String, _ fields: [String: Any] = [:]) {
        var result = fields; result["event"] = event; result["uptime"] = ProcessInfo.processInfo.systemUptime; result["pid"] = getpid()
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else { return }
        eventLock.lock(); defer { eventLock.unlock() }
        print("MIC_GRAPH_EVENT " + String(decoding: data, as: UTF8.self)); fflush(stdout)
    }
    private func checkDeadline() throws {
        stateLock.lock(); let timedOut = expired; stateLock.unlock()
        if timedOut { throw Failure("45 second diagnostic deadline exceeded") }
    }
    private func stage<T>(_ name: String, _ body: () throws -> T) throws -> T {
        try checkDeadline()
        stateLock.lock(); activeStage = name; stateLock.unlock()
        let start = ProcessInfo.processInfo.systemUptime, before = oldMeter.snapshot
        emit("stageBegin", ["name": name])
        defer {
            emit("stageEnd", ["name": name, "seconds": ProcessInfo.processInfo.systemUptime - start,
                "oldOutputExpectedRunning": oldExpectedRunning, "oldOutput": oldMeter.window(from: start, baseline: before)])
            stateLock.lock(); activeStage = "between-stages"; stateLock.unlock()
        }
        let result = try body(); try checkDeadline(); return result
    }
    private func wait(_ seconds: Double) throws { Thread.sleep(forTimeInterval: seconds); try checkDeadline() }
    private func armWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 45)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.stateLock.lock(); self.expired = true; let stage = self.activeStage; self.stateLock.unlock()
            // Never abandon a native call or release a possibly live hardware owner.
            self.emit("deadlineExceeded", ["stage": stage, "cleanupPending": true, "nativeCallAbandoned": false])
        }
        watchdog = timer; timer.resume()
    }
    private func run() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            emit("finished", ["completed": false, "error": "Existing microphone permission required; no prompt"]); exit(2)
        }
        armWatchdog()
        var completed = false, acceptance = false
        do {
            emit("identity", ["bundle": Bundle.main.bundleIdentifier ?? "", "tonePeak": 0.015,
                "networkConstructed": false, "handoffTested": stoppedArm, "stoppedCandidateArm": stoppedArm,
                "acousticContinuityQualified": false, "audioWorkerMainThread": Thread.isMainThread])
            try stage("old-output-create-configure") {
                let engine = AVAudioEngine(); old = engine
                let hardware = engine.outputNode.outputFormat(forBus: 0)
                guard hardware.sampleRate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: 1) else { throw Failure("Invalid old output format") }
                oldSampleRate = format.sampleRate
                let tone = Tone(sampleRate: format.sampleRate, gain: 0.015, meter: oldMeter)
                let source = AVAudioSourceNode(format: format) { _, _, frames, buffers in tone.render(frames, buffers) }
                oldSource = source; engine.attach(source)
                engine.connect(source, to: engine.mainMixerNode, format: format)
                engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
                emit("oldFormat", ["sampleRate": format.sampleRate, "channels": format.channelCount])
            }
            try stage("old-output-prepare") { old!.prepare() }
            try stage("old-output-stabilize-100ms") { Thread.sleep(forTimeInterval: 0.1) }
            try stage("old-output-start") { try old!.start() }
            try wait(2)
            let beforeStart = ProcessInfo.processInfo.systemUptime, before = oldMeter.snapshot
            try wait(5)
            let baseline = oldMeter.window(from: beforeStart, baseline: before)
            emit("oldOutputBefore", baseline)
            guard baseline["continuous"] as? Bool == true else { throw Failure("Old output did not establish continuous rendering") }
            let transitionStart = ProcessInfo.processInfo.systemUptime, transition = oldMeter.snapshot
            try stage("replacement-create") { replacement = AVAudioEngine() }
            try stage("replacement-set-vpio") {
                let input = replacement!.inputNode; tappedInput = input
                try input.setVoiceProcessingEnabled(true)
                input.isVoiceProcessingBypassed = false; input.isVoiceProcessingAGCEnabled = true
                input.isVoiceProcessingInputMuted = false
                if #available(macOS 14.0, *) {
                    var ducking = input.voiceProcessingOtherAudioDuckingConfiguration
                    ducking.enableAdvancedDucking = false; ducking.duckingLevel = .min
                    input.voiceProcessingOtherAudioDuckingConfiguration = ducking
                }
                guard input.isVoiceProcessingEnabled, !input.isVoiceProcessingBypassed else { throw Failure("Normal VPIO was not enabled") }
            }
            try stage("replacement-configure") {
                let hardware = tappedInput!.outputFormat(forBus: 0)
                guard hardware.sampleRate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: 1) else { throw Failure("Invalid VPIO format") }
                candidateFormat = format; try wireReplacement(format: format, gain: 0, meter: silentMeter)
            }
            try stage("replacement-prepare") { replacement!.prepare(); try validateReplacement() }
            try stage("replacement-stabilize-100ms") { Thread.sleep(forTimeInterval: 0.1) }
            if stoppedArm {
                acceptance = try adoptStoppedCandidate(from: transitionStart, baseline: transition)
            } else {
            try stage("replacement-start") { try replacement!.start(); try validateReplacement() }
            let during = oldMeter.window(from: transitionStart, baseline: transition)
            emit("oldOutputDuringReplacement", during)
            let coexistStart = ProcessInfo.processInfo.systemUptime, coexist = oldMeter.snapshot, inputBefore = inputMeter.snapshot
            try wait(5)
            let after = oldMeter.window(from: coexistStart, baseline: coexist)
            let input = inputMeter.window(from: coexistStart, baseline: inputBefore)
            acceptance = during["continuous"] as? Bool == true && after["continuous"] as? Bool == true &&
                (input["callbacks"] as? Int ?? 0) >= 3 && old!.isRunning && replacement!.isRunning
            emit("coexistingGraphs", ["oldOutput": after, "input": input, "replacementOutput": silentMeter.window(from: coexistStart, baseline: .init()),
                "oldRunning": old!.isRunning, "replacementRunning": replacement!.isRunning, "acceptance": acceptance,
                "speechClassified": false, "acousticContinuityQualified": false])
            }
            completed = true
        } catch { emit("failed", ["error": String(describing: error)]) }
        stateLock.lock(); activeStage = "cleanup"; stateLock.unlock()
        let stopped = cleanup(); watchdog?.cancel(); watchdog = nil
        emit("finished", ["completed": completed, "acceptance": acceptance && stopped, "cleanupConfirmed": stopped,
            "nativeCallAbandoned": false, "handoffTested": stoppedArm, "acousticContinuityQualified": false])
        if stopped { Self.owner = nil; exit(completed ? 0 : 1) }
        // Keep the owner alive for inspection if a native hardware stop was not confirmed.
    }
    private func wireReplacement(format: AVAudioFormat, gain: Double, meter: Meter) throws {
        let engine = replacement!, input = tappedInput!, tone = Tone(sampleRate: format.sampleRate, gain: gain, meter: meter)
        let source = AVAudioSourceNode(format: format) { _, _, frames, buffers in tone.render(frames, buffers) }
        newSource = source; engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format); engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        let mixer = AVAudioMixerNode(), sink = AVAudioSinkNode { _, _, _ in noErr }
        inputMixer = mixer; inputSink = sink; engine.attach(mixer); engine.attach(sink)
        engine.connect(input, to: mixer, format: format); engine.connect(mixer, to: sink, format: format)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [inputMeter] buffer, _ in inputMeter.consume(buffer) }; tapInstalled = true
        mixer.outputVolume = 0
        guard mixer.outputVolume == 0, input.isVoiceProcessingEnabled, !input.isVoiceProcessingBypassed else { throw Failure("Wired graph lost mute or normal VPIO") }
        emit("replacementFormat", ["sampleRate": format.sampleRate, "channels": format.channelCount, "oldSampleRate": oldSampleRate,
            "oldAndReplacementFormatsMatch": oldSampleRate == format.sampleRate, "voiceProcessing": input.isVoiceProcessingEnabled,
            "bypassed": input.isVoiceProcessingBypassed, "AGC": input.isVoiceProcessingAGCEnabled, "inputMixerVolume": mixer.outputVolume, "outputTonePeak": gain])
    }
    private func detachReplacementNodes() {
        if let input = tappedInput, tapInstalled { input.removeTap(onBus: 0); tapInstalled = false }
        if let engine = replacement {
            for node in [newSource as AVAudioNode?, inputMixer, inputSink].compactMap({ $0 }) {
                engine.disconnectNodeInput(node); engine.disconnectNodeOutput(node); engine.detach(node)
            }
        }
        newSource = nil; inputMixer = nil; inputSink = nil
    }
    private func validateReplacement() throws {
        guard inputMixer?.outputVolume == 0, tappedInput?.isVoiceProcessingEnabled == true,
              tappedInput?.isVoiceProcessingBypassed == false else { throw Failure("Prepared/started graph lost staging mute or VPIO") }
        emit("replacementState", ["running": replacement!.isRunning, "inputMixerVolume": inputMixer!.outputVolume,
            "voiceProcessing": tappedInput!.isVoiceProcessingEnabled, "bypassed": tappedInput!.isVoiceProcessingBypassed])
    }
    private func adoptStoppedCandidate(from start: Double, baseline: Meter.Snapshot) throws -> Bool {
        emit("beforeOldStop", ["oldLastCallbackUptime": oldMeter.snapshot.lastCallbackUptime as Any? ?? NSNull(),
            "oldOutputDuringStoppedPreparation": oldMeter.window(from: start, baseline: baseline), "inputBefore": inputMeter.window(from: start, baseline: .init())])
        try stage("adoption-old-stop") { old!.stop(); oldExpectedRunning = false }
        let oldLast = oldMeter.snapshot.lastCallbackUptime, oldUntilStop = oldMeter.window(from: start, baseline: baseline)
        let inputID = ObjectIdentifier(tappedInput!), outputID = ObjectIdentifier(replacement!.outputNode)
        try stage("adoption-rewire-all-custom-nodes") {
            guard !replacement!.isRunning, !old!.isRunning else { throw Failure("Rewire requires both engines stopped") }
            retiredSource = newSource; retiredMixer = inputMixer; retiredSink = inputSink
            try autoreleasepool { detachReplacementNodes(); try wireReplacement(format: candidateFormat!, gain: 0.015, meter: adoptedMeter) }
        }
        let nodesReleased = retiredSource == nil && retiredMixer == nil && retiredSink == nil
        let sameIONodes = ObjectIdentifier(replacement!.inputNode) == inputID && ObjectIdentifier(replacement!.outputNode) == outputID
        emit("retiredTemporaryNodes", ["sourceReleased": retiredSource == nil, "mixerReleased": retiredMixer == nil, "sinkReleased": retiredSink == nil,
            "sameIONodes": sameIONodes])
        try stage("adoption-reprepare") { replacement!.prepare(); try validateReplacement() }
        try stage("adoption-stabilize-100ms") { Thread.sleep(forTimeInterval: 0.1) }
        try stage("adoption-start") { try replacement!.start(); try validateReplacement() }
        let steadyStart = ProcessInfo.processInfo.systemUptime, steady = adoptedMeter.snapshot, inputBefore = inputMeter.snapshot
        try wait(5)
        let output = adoptedMeter.window(from: steadyStart, baseline: steady), input = inputMeter.window(from: steadyStart, baseline: inputBefore)
        let firstNew = adoptedMeter.snapshot.firstCallbackUptime, gap = firstNew.flatMap { first in oldLast.map { first - $0 } }
        let joinedGap = gap.map { max($0, max(oldUntilStop["maximumCallbackGap"] as? Double ?? 0, output["maximumCallbackGap"] as? Double ?? 0)) }
        let passed = nodesReleased && sameIONodes && joinedGap.map { $0 >= 0 && $0 < 0.35 } == true && output["continuous"] as? Bool == true &&
            (input["callbacks"] as? Int ?? 0) >= 3 && replacement!.isRunning && !old!.isRunning
        emit("stoppedCandidateAdoption", ["oldLastCallbackUptime": oldLast as Any? ?? NSNull(), "firstNewAudibleCallbackUptime": firstNew as Any? ?? NSNull(),
            "oldLastToNewFirstSeconds": gap as Any? ?? NSNull(), "joinedMaximumCallbackGap": joinedGap as Any? ?? NSNull(),
            "oldOutputUntilStop": oldUntilStop, "replacementOutput": output, "inputAfter": input, "acceptance": passed,
            "oldStoppedAgeExcludedFromJoinedGap": true, "sameFormatsReused": true, "acousticContinuityQualified": false])
        return passed
    }
    private func cleanup() -> Bool {
        replacement?.stop(); old?.stop()
        var statuses: [OSStatus] = []
        if let unit = tappedInput?.audioUnit { statuses.append(AudioOutputUnitStop(unit)) }
        for engine in [replacement, old].compactMap({ $0 }) {
            if let unit = engine.outputNode.audioUnit { statuses.append(AudioOutputUnitStop(unit)) }
        }
        let stopped = old?.isRunning != true && replacement?.isRunning != true &&
            statuses.allSatisfy { $0 == noErr || $0 == kAudioUnitErr_Uninitialized }
        detachReplacementNodes()
        if let engine = old, let source = oldSource { engine.disconnectNodeOutput(source); engine.detach(source) }
        emit("cleanup", ["confirmed": stopped, "audioUnitStopStatuses": statuses])
        if stopped { oldSource = nil; tappedInput = nil; candidateFormat = nil; replacement = nil; old = nil }
        return stopped
    }
    private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }

    private final class Meter: @unchecked Sendable {
        struct Snapshot {
            var callbacks = 0, samples = 0; var energy = 0.0
            var firstCallbackUptime: Double?, lastCallbackUptime: Double?
        }
        private let lock = NSLock()
        private var measured = Snapshot(), timeline = GuestFrameTimeline()
        var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return measured }
        func record(samples: Int, energy: Double, at now: Double) {
            guard samples > 0 else { return }
            lock.lock(); defer { lock.unlock() }
            measured.callbacks += 1; measured.samples += samples; measured.energy += energy; timeline.record(now)
            measured.firstCallbackUptime = min(measured.firstCallbackUptime ?? now, now)
            measured.lastCallbackUptime = max(measured.lastCallbackUptime ?? now, now)
        }
        func consume(_ buffer: AVAudioPCMBuffer) {
            let now = ProcessInfo.processInfo.systemUptime
            var energy = 0.0, samples = 0
            guard let channels = buffer.floatChannelData else { return }
            for channel in 0..<Int(buffer.format.channelCount) {
                for index in 0..<Int(buffer.frameLength) {
                    let value = Double(channels[channel][index]); if value.isFinite { energy += value * value; samples += 1 }
                }
            }
            record(samples: samples, energy: energy, at: now)
        }
        func window(from start: Double, baseline: Snapshot) -> [String: Any] {
            let end = ProcessInfo.processInfo.systemUptime
            lock.lock(); defer { lock.unlock() }
            let cadence = timeline.measure(from: start, to: end), samples = measured.samples - baseline.samples, energy = measured.energy - baseline.energy
            return ["start": start, "end": end, "seconds": end - start, "callbacks": measured.callbacks - baseline.callbacks,
                "samples": samples, "energy": energy, "rms": samples > 0 ? sqrt(max(0, energy) / Double(samples)) : 0,
                "firstCallbackUptime": measured.firstCallbackUptime as Any? ?? NSNull(), "lastCallbackUptime": measured.lastCallbackUptime as Any? ?? NSNull(),
                "maximumCallbackGap": cadence.maximumGap, "endCallbackAge": cadence.endFrameAge as Any? ?? NSNull(),
                "complete": cadence.complete, "continuous": cadence.complete && samples > 0 && energy > 0 && cadence.maximumGap < 0.35 && cadence.endFrameAge.map { $0 < 0.1 } == true]
        }
    }
    private final class Tone: @unchecked Sendable {
        private let lock = NSLock(), meter: Meter, step: Double, gain: Double
        private var phase = 0.0
        init(sampleRate: Double, gain: Double, meter: Meter) { step = 2 * .pi * 440 / sampleRate; self.gain = gain; self.meter = meter }
        func render(_ frames: AVAudioFrameCount, _ buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock(); defer { lock.unlock() }
            var samples = 0, energy = 0.0
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                guard let data = buffer.mData else { continue }
                let values = data.assumingMemoryBound(to: Float.self), count = min(Int(frames) * Int(buffer.mNumberChannels), Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                for index in 0..<count {
                    let value = gain == 0 ? 0 : gain * sin(phase); values[index] = Float(value)
                    phase += step; if phase >= 2 * .pi { phase -= 2 * .pi }
                    energy += value * value; samples += 1
                }
            }
            meter.record(samples: samples, energy: energy, at: now); return noErr
        }
    }
}
#endif
