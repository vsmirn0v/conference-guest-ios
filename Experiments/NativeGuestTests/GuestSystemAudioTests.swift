import AVFoundation
import Foundation

@main struct GuestSystemAudioTests {
    static func main() {
        // All fixtures are memory-only. These tests never create a factory or access audio devices.
        for format: AVAudioCommonFormat in [.pcmFormatInt16, .pcmFormatInt32, .pcmFormatFloat32, .pcmFormatFloat64] {
            for interleaved in [true, false] {
                let meter = GuestPCMMeter()
                let pcm = buffer(format, interleaved: interleaved)
                meter.render(pcmBuffer: pcm)
                precondition(meter.snapshot.samples == 960)
                precondition(abs(meter.snapshot.rms - 0.5) < 1e-12)
                precondition(meter.buffers == 1)
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
        print("PASS: memory-only PCM meters, exclusive private/meeting owner leases, speech/music constraints, video windows and audio operation timing")
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
