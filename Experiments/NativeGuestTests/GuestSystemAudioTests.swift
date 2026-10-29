import AVFoundation
import Foundation

private final class StartupGainFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Double
    private var writes: [Double] = []
    init(_ value: Double) { stored = value }
    var value: Double { lock.lock(); defer { lock.unlock() }; return stored }
    var history: [Double] { lock.lock(); defer { lock.unlock() }; return writes }
    func set(_ value: Double) { lock.lock(); stored = value; writes.append(value); lock.unlock() }
}

@main struct GuestSystemAudioTests {
    @MainActor static func main() async {
        // All fixtures are memory-only. These tests never create a factory or access audio devices.
        for format: AVAudioCommonFormat in [.pcmFormatInt16, .pcmFormatInt32, .pcmFormatFloat32, .pcmFormatFloat64] {
            for interleaved in [true, false] {
                let meter = GuestPCMMeter()
                let pcm = buffer(format, interleaved: interleaved)
                meter.render(pcmBuffer: pcm)
                precondition(meter.snapshot.samples == 960)
                precondition(abs(meter.snapshot.rms - 0.5) < 1e-12)
                precondition(meter.buffers == 1)
#if DEBUG
                precondition(meter.callbackEvidence["frames"] as? Int == 480)
                precondition(meter.callbackEvidence["sampleRate"] as? Double == 48000)
#endif
                precondition(abs((meter.level ?? 0) - 0.5) < 0.00001)
                let before = meter.snapshot
                meter.render(pcmBuffer: pcm)
                let window = meter.snapshot.since(before)
                precondition(window.samples == 960 && abs(window.rms - 0.5) < 1e-12)
                meter.reset()
                precondition(meter.snapshot.samples == 0 && meter.snapshot.energy == 0 && meter.buffers == 0)
                precondition(meter.level == nil)
            }
        }
        let meter = GuestPCMMeter(), silence = buffer(.pcmFormatFloat32, interleaved: false)
        for channel in 0..<2 { silence.floatChannelData![channel].initialize(repeating: 0, count: 480) }
        meter.render(pcmBuffer: silence)
        precondition(meter.snapshot.samples == 960 && meter.snapshot.energy == 0)
        let before = meter.snapshot
        silence.floatChannelData![0][0] = .nan
        silence.floatChannelData![0][1] = .infinity
        meter.render(pcmBuffer: silence)
        precondition(meter.snapshot.since(before).samples == 958 && meter.snapshot.energy.isFinite)
        let empty = buffer(.pcmFormatFloat32, interleaved: false)
        empty.frameLength = 0
        let samples = meter.snapshot.samples
        meter.render(pcmBuffer: empty)
        precondition(meter.snapshot.samples == samples)
        let concurrent = GuestPCMMeter(), pcm = buffer(.pcmFormatInt16, interleaved: true)
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in concurrent.render(pcmBuffer: pcm) }
        precondition(concurrent.snapshot.samples == 960_000 && concurrent.buffers == 1000)
        precondition(abs(concurrent.snapshot.rms - 0.5) < 1e-12)
        videoWindowEvidence()
        ownerLeaseAndProfiles()
        operationTraceEvidence()
        startupGainRegistry()
        startupGainSDKReentry()
        startupGraphStability()
        startupDeliveredCallbackCadence()
        await startupSnapshotBudget()
        print("PASS: memory-only PCM meters, exclusive private/meeting owner leases, speech/music constraints, video windows and audio operation timing")
    }

    @MainActor private static func startupGainRegistry() {
        let gain = GuestStartupPlaybackGain(sound: true), identity = NSObject()
        var volume = 0.7
        func register() { gain.register(identity: identity, gain: { volume }, setGain: { volume = $0 }) }
        register(); precondition(volume == 0 && gain.hasSources && !gain.isOpen)
        register(); gain.remove(identity); precondition(!gain.hasSources)
        register(); precondition(volume == 0 && gain.hasSources)
        precondition(gain.open() && volume == 0.7, "Duplicates and reattachment preserve original gain")
        gain.setSound(false); precondition(volume == 0)
        gain.setSound(true); precondition(volume == 0.7)
        gain.close(); precondition(volume == 0 && !gain.open())
        register(); precondition(volume == 0 && !gain.hasSources, "A stale callback cannot open or retain an old owner")
        let armed = GuestStartupPlaybackGain(sound: false), late = NSObject()
        var lateVolume = 1.0
        precondition(!armed.open(), "Sound-off does not open an empty gate")
        armed.setSound(true)
        armed.register(identity: late, gain: { lateVolume }, setGain: { lateVolume = $0 })
        precondition(lateVolume == 0 && !armed.isOpen, "Later receivers stay silent until their own witness")
        precondition(armed.open() && lateVolume == 1)
        armed.close()
    }

    @MainActor private static func startupGainSDKReentry() {
        let gate = GuestStartupPlaybackGain(sound: true)
        let first = NSObject(), signaling = NSObject(), reentrant = NSObject()
        let firstGain = StartupGainFixture(0.6), signalingGain = StartupGainFixture(0.8), reentrantGain = StartupGainFixture(0.4)
        var simulated = false
        gate.register(identity: first, gain: { firstGain.value }, setGain: { value in
            firstGain.set(value)
            guard value > 0, !simulated else { return }
            simulated = true
            // Model an SDK BlockingCall that needs the signaling callback to return.
            let returned = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                gate.register(identity: signaling, gain: { signalingGain.value }, setGain: { signalingGain.set($0) })
                returned.signal()
            }
            precondition(returned.wait(timeout: .now() + 1) == .success,
                "SDK I/O may not hold a lock needed by the signaling callback")
            // SDK reentry may also register on the same thread.
            gate.register(identity: reentrant, gain: { reentrantGain.value }, setGain: { reentrantGain.set($0) })
        })
        precondition(gate.open() && simulated)
        precondition(signalingGain.value == 0 && reentrantGain.value == 0,
            "A callback only mutes; positive restoration waits for MainActor reconciliation")
        gate.reconcile()
        precondition(firstGain.value == 0.6 && signalingGain.value == 0.8 && reentrantGain.value == 0.4)
        gate.close()
        let oldWrites = signalingGain.history.count
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            gate.register(identity: signaling, gain: { signalingGain.value }, setGain: { signalingGain.set($0) })
            returned.signal()
        }
        precondition(returned.wait(timeout: .now() + 1) == .success)
        gate.reconcile()
        precondition(signalingGain.history.dropFirst(oldWrites).allSatisfy { $0 == 0 } && !gate.open(),
            "A stale callback never writes positive gain after close returns")
    }

    private static func startupGraphStability() {
        let format: [Double] = [48000, 1819304813, 41, 4, 1, 4, 1, 32, 0]
        var snapshot: [String: Any] = ["engineRunning": true, "inputAvailable": true, "inputEnabled": false,
            "inputRunning": false, "outputAvailable": true, "outputEnabled": true,
            "inputASBD": format, "outputASBD": format, "engineStarts": 1]
        func observation(_ tick: Int) -> GuestStartupAudioObservation {
            .init(snapshot: snapshot, inputCallbacks: UInt64(tick), outputCallbacks: UInt64(tick))
        }
        var stability = GuestStartupAudioStability()
        for tick in 0..<6 { precondition(!stability.observe(observation(tick), input: true, at: Double(tick) / 10), "The early output-only graph is not ready") }
        snapshot["inputEnabled"] = true; snapshot["inputRunning"] = true
        snapshot["outputEnabled"] = false // An empty room can render coupled output from local input demand.
        for tick in 6..<10 { precondition(!stability.observe(observation(tick), input: true, at: Double(tick) / 10)) }
        precondition(stability.observe(observation(10), input: true, at: 1), "Empty-room coupled output qualifies through silent callbacks without raw output demand or energy")
        snapshot["engineStarts"] = 2
        precondition(!stability.observe(observation(11), input: true, at: 1.1), "A graph restart resets the entire window")
        for tick in 12..<15 { precondition(!stability.observe(observation(tick), input: true, at: Double(tick) / 10)) }
        precondition(stability.observe(observation(15), input: true, at: 1.5))
        precondition(!stability.observe(observation(15), input: true, at: 1.7), "Stalled silent callbacks do not prove readiness")
#if DEBUG
        precondition(stability.lastDecision == "callbackStale")
        precondition(observation(15).evidence["outputCallbacks"] as? UInt64 == 15)
        var report = GuestStartupAudioReport(configuredUptime: 0, initialSoundIntent: true, latestSoundIntent: true)
        for index in 0..<30 { report.record(["index": index]) }
        precondition(report.observations.count == 20 && report.observations.first?["index"] as? Int == 10,
            "Failure evidence stays bounded and preserves the final observations")
#endif
        var changed = format; changed[2] = 9; snapshot["outputASBD"] = changed
        precondition(!stability.observe(observation(18), input: true, at: 1.8), "Full ASBD changes reset readiness")
    }

    private static func startupDeliveredCallbackCadence() {
        let nativeFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let native = withExtendedLifetime(nativeFormat) { nativeFormat.streamDescription.pointee }
        let actual = GuestStartupAudioCallback.Format(native)
        let configured: [Double] = [48000, 1819304813, 41, 4, 1, 4, 1, 32, 0]
        let snapshot: [String: Any] = ["engineRunning": true, "inputAvailable": true, "inputEnabled": true,
            "inputRunning": true, "outputAvailable": true, "outputEnabled": false,
            "inputASBD": configured, "outputASBD": configured, "engineStarts": 1]
        func observation(_ tick: Int, frames: Int = 4800, format: GuestStartupAudioCallback.Format? = nil,
                         outputTick: Int? = nil) -> GuestStartupAudioObservation {
            let outputTick = outputTick ?? (tick / 4) * 4
            let input = GuestStartupAudioCallback(count: UInt64(tick / 2 + 1), frames: 2400,
                format: actual, uptime: 10 + Double((tick / 2) * 2) * 0.05)
            let output = GuestStartupAudioCallback(count: UInt64(outputTick / 4 + 1), frames: frames,
                format: format ?? actual, uptime: 10 + Double(outputTick) * 0.05)
            return .init(snapshot: snapshot, inputCallbacks: input.count, outputCallbacks: output.count,
                inputCallback: input, outputCallback: output)
        }
        var stability = GuestStartupAudioStability()
        for tick in 0..<7 { precondition(!stability.observe(observation(tick), input: true, at: 10 + Double(tick) * 0.05)) }
        let ready = stability.observe(observation(8), input: true, at: 10.4)
        precondition(ready,
            "Silent 200ms delivered output buffers qualify despite stale configured48k ASBD")
        precondition(abs(observation(8).outputCallback.freshness - 0.3) < 0.000001)
        var stalled = GuestStartupAudioStability()
        for tick in 0..<20 {
            precondition(!stalled.observe(observation(0), input: true, at: 10 + Double(tick) * 0.05),
                "A constant callback count never proves progress")
        }
        for gap in [0.35, 0.36] {
            precondition(!stability.observe(observation(14, outputTick: 8), input: true, at: 10.4 + gap),
                "A callback gap at or above350ms cannot qualify continuity")
        }
        var capped = GuestStartupAudioStability()
        _ = capped.observe(observation(0, frames: 7200), input: true, at: 10)
        precondition(capped.observe(observation(8, frames: 7200), input: true, at: 10.4))
        precondition(!capped.observe(observation(14, frames: 7200, outputTick: 8), input: true, at: 10.4 + 0.35),
            "Receipt age exactly350ms fails even when the scheduling allowance reaches its cap")
        for frames in [8400, 9600] {
            precondition(!observation(8, frames: frames).supports(input: true),
                "Nominal delivered cadence at or above350ms is explicitly unsupported")
        }
        var changed = native; changed.mFormatFlags ^= 1
        var transition = GuestStartupAudioStability()
        _ = transition.observe(observation(0), input: true, at: 10)
        precondition(transition.observe(observation(8), input: true, at: 10.4))
        precondition(!transition.observe(observation(9, format: .init(changed)), input: true, at: 10.45),
            "Actual full ASBD changes reset stability while the configured ASBD stays unchanged")
        precondition(!transition.observe(observation(10, frames: 2400), input: true, at: 10.5),
            "Delivered buffer/cadence changes reset stability")
    }

    @MainActor private static func startupSnapshotBudget() async {
        var now = 3.0, supplied = 0.0, reads = 0
        let within = await GuestStartupAudioBudget.refresh(deadline: 8, clock: { now }, read: {
            supplied = $0; reads += 1; now += 2.4; return true
        })
        precondition(within && supplied == 5 && reads == 1,
            "A 2.4-second native snapshot uses the actual remaining budget and may finish before the unchanged deadline")
        for completion in [8.0, 8.1] {
            now = 3
            let accepted = await GuestStartupAudioBudget.refresh(deadline: 8, clock: { now }, read: {
                precondition($0 == 5); now = completion; return true
            })
            precondition(!accepted, "Success exactly at or after the deadline cannot qualify readiness")
        }
        now = 8; reads = 0
        let expired = await GuestStartupAudioBudget.refresh(deadline: 8, clock: { now }, read: { _ in reads += 1; return true })
        precondition(!expired && reads == 0, "Expired budget must not start another native read")
        now = 3
        let failed = await GuestStartupAudioBudget.refresh(deadline: 8, clock: { now }, read: { _ in false })
        precondition(!failed, "An unsuccessful read remains a failure even with time left")
    }

    private static func operationTraceEvidence() {
        let trace = GuestAudioOperationTrace()
        let activation = trace.enqueue("microphone-activate", timeout: 2, at: 10)
        let mute = trace.enqueue("microphone-mute", timeout: 2, at: 10.1)
        trace.start(activation, at: 10.2)
        trace.beginNativeCall("set-engine-availability", at: 10.3)
        trace.timedOut(activation, at: 12)
        trace.timedOut(mute, at: 12.1)
        var snapshot = trace.snapshot(at: 12.5)
        var active = snapshot["audioActiveOperation"] as! [String: Any]
        precondition(active["name"] as? String == "microphone-activate")
        precondition(active["stage"] as? String == "native-call")
        precondition(active["callerTimedOut"] as? Bool == true)
        precondition(abs((active["nativeSeconds"] as! Double) - 2.2) < 0.00001)
        precondition(snapshot["audioQueuedOperations"] as? Int == 1)
        trace.endNativeCall(result: "-1", at: 13)
        trace.beginNativeCall("read-native-snapshot", at: 13.1)
        trace.endNativeCall(result: "complete", at: 13.2)
        trace.finish(activation, succeeded: false, at: 13.3)
        trace.start(mute, at: 13.4)
        trace.finish(mute, succeeded: true, at: 13.5)
        snapshot = trace.snapshot(at: 14)
        let history = snapshot["audioOperations"] as! [[String: Any]]
        precondition(history.count == 2 && snapshot["audioQueuedOperations"] as? Int == 0)
        precondition((snapshot["audioActiveOperation"] as! [String: Any]).isEmpty)
        precondition(history[0]["succeeded"] as? Bool == false)
        precondition(history[1]["callerTimedOut"] as? Bool == true && history[1]["succeeded"] as? Bool == true)
        precondition(abs((history[1]["queueSeconds"] as! Double) - 3.3) < 0.00001)
        let native = history[0]["nativeCalls"] as! [[String: Any]]
        precondition(native.count == 2 && native[0]["result"] as? String == "-1")
        precondition(abs((native[0]["seconds"] as! Double) - 2.7) < 0.00001)
        precondition(JSONSerialization.isValidJSONObject(snapshot))
        // Completed history stays bounded without losing a queued/running operation.
        let pending = trace.enqueue("shutdown", timeout: 2, at: 20)
        for index in 0..<40 {
            let id = trace.enqueue("snapshot", timeout: 2, at: Double(21 + index))
            trace.start(id, at: Double(21 + index)); trace.finish(id, succeeded: true, at: Double(21 + index))
        }
        trace.start(pending, at: 65)
        active = trace.snapshot(at: 66)["audioActiveOperation"] as! [String: Any]
        precondition(active["name"] as? String == "shutdown")
        precondition((trace.snapshot(at: 66)["audioOperations"] as! [[String: Any]]).count <= 18)
    }

    private static func ownerLeaseAndProfiles() {
        var meeting = GuestAudioOwnerLease(privateCheck: false)
        precondition(meeting != nil && GuestAudioOwnerLease(privateCheck: true) == nil)
        var secondMeeting = GuestAudioOwnerLease(privateCheck: false)
        precondition(secondMeeting != nil)
        meeting = nil
        precondition(GuestAudioOwnerLease(privateCheck: true) == nil)
        secondMeeting = nil
        var check = GuestAudioOwnerLease(privateCheck: true)
        precondition(check != nil)
        precondition(GuestAudioOwnerLease(privateCheck: false) == nil && GuestAudioOwnerLease(privateCheck: true) == nil)
        check = nil
        precondition(GuestAudioOwnerLease(privateCheck: false) != nil)
        let speech = GuestAudioProfile.speech, music = GuestAudioProfile.music
        precondition(speech.usesPlatformVoiceProcessing && !music.usesPlatformVoiceProcessing)
        precondition(speech.audioConstraints == ["googEchoCancellation": "true", "googNoiseSuppression": "true", "googAutoGainControl": "true"])
        precondition(music.audioConstraints == ["googEchoCancellation": "true", "googNoiseSuppression": "false", "googAutoGainControl": "false"])
        var activation = GuestInputActivationPolicy(persistent: false)
        precondition(!activation.inputAvailable)
        activation.beginCheck(); precondition(activation.inputAvailable)
        activation.endCheck(); precondition(!activation.inputAvailable)
        activation.beginCheck(); activation.activate(); activation.endCheck()
        precondition(activation.inputAvailable, "A later manual/accessory activation must survive private check cleanup")
        activation = .init(persistent: true); activation.beginCheck(); activation.endCheck()
        precondition(activation.inputAvailable)
        GuestAudioOwnerLease.reportFailedStop()
        precondition(GuestAudioOwnerLease(privateCheck: false) == nil && GuestAudioOwnerLease(privateCheck: true) == nil,
                     "An unconfirmed hardware stop must block every new owner until app restart")
    }

    private static func videoWindowEvidence() {
        func snapshot(_ frames: Int, changes: Int = 0, connected: Bool = true, failed: Bool = false) -> GuestMediaSnapshot {
            .init(render: ["advancingFrames": frames, "pixelChanges": changes], audio: .init(), connected: connected, failed: failed)
        }
        // A surviving peer can have hundreds of old frames across reconnect.
        // Readiness must require fresh progress on BOTH current baselines.
        let survivor = snapshot(700, changes: 699), newPeer = snapshot(6, changes: 5)
        let local = NSObject(), remote = NSObject(), replacement = NSObject()
        let localID = ObjectIdentifier(local), remoteID = ObjectIdentifier(remote)
        var readiness = GuestVideoReadiness(localID: localID, remoteID: remoteID, local: survivor, remote: newPeer)
        precondition(!readiness.observe(localID: localID, remoteID: remoteID, local: survivor, remote: snapshot(30, changes: 29)))
        precondition(!readiness.observe(localID: localID, remoteID: remoteID, local: snapshot(725, changes: 724), remote: newPeer))
        precondition(!readiness.observe(localID: localID, remoteID: remoteID, local: snapshot(5, changes: 4), remote: snapshot(30, changes: 29)))
        precondition(!readiness.observe(localID: localID, remoteID: remoteID, local: snapshot(725, changes: 699), remote: snapshot(30, changes: 29)))
        precondition(!readiness.observe(localID: localID, remoteID: remoteID, local: snapshot(725, changes: 724, connected: false), remote: snapshot(30, changes: 29)))
        precondition(!readiness.observe(localID: localID, remoteID: remoteID, local: snapshot(725, changes: 724), remote: snapshot(30, changes: 29, failed: true)))
        precondition(readiness.observe(localID: localID, remoteID: remoteID, local: snapshot(725, changes: 724), remote: snapshot(30, changes: 29)))
        // Even a replacement that already has frames cannot reuse either old baseline.
        let nextID = ObjectIdentifier(replacement)
        precondition(!readiness.observe(localID: localID, remoteID: nextID, local: snapshot(750, changes: 749), remote: snapshot(20, changes: 19)))
        precondition(!readiness.observe(localID: localID, remoteID: nextID, local: snapshot(750, changes: 749), remote: snapshot(40, changes: 39)))
        precondition(readiness.observe(localID: localID, remoteID: nextID, local: snapshot(775, changes: 774), remote: snapshot(40, changes: 39)))
        let before = snapshot(100), staticScene = snapshot(162)
        precondition(staticScene.hasFreshVideo(since: before, expectation: .nativeCamera(capturedFrames: 60)))
        precondition(!staticScene.hasFreshVideo(since: before, expectation: .movingPattern))
        for captured in [nil, 0, -1, 10] as [Int?] {
            precondition(!staticScene.hasFreshVideo(since: before, expectation: .nativeCamera(capturedFrames: captured)))
        }
        for frames in [0, 100, 110] {
            precondition(!snapshot(frames).hasFreshVideo(since: before, expectation: .nativeCamera(capturedFrames: 60)))
        }
        precondition(!snapshot(162, connected: false).hasFreshVideo(since: before, expectation: .nativeCamera(capturedFrames: 60)))
        precondition(!snapshot(162, failed: true).hasFreshVideo(since: before, expectation: .nativeCamera(capturedFrames: 60)))
        precondition(snapshot(162, changes: 6).hasFreshVideo(since: before, expectation: .movingPattern))
    }

    private static func buffer(_ common: AVAudioCommonFormat, interleaved: Bool) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: common, sampleRate: 48_000, channels: 2, interleaved: interleaved)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        pcm.frameLength = 480
        for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
            let count = 480 * Int(buffer.mNumberChannels), data = buffer.mData!
            switch common {
            case .pcmFormatInt16: data.assumingMemoryBound(to: Int16.self).initialize(repeating: 16384, count: count)
            case .pcmFormatInt32: data.assumingMemoryBound(to: Int32.self).initialize(repeating: 1073741824, count: count)
            case .pcmFormatFloat32: data.assumingMemoryBound(to: Float.self).initialize(repeating: 0.5, count: count)
            case .pcmFormatFloat64: data.assumingMemoryBound(to: Double.self).initialize(repeating: 0.5, count: count)
            default: preconditionFailure("Unsupported test format")
            }
        }
        return pcm
    }
}
