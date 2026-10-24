#if DEBUG
import Foundation

extension CompanionMeetingController {
    // Access is intentionally through a controller-owned snapshot supplied below.
    static func captureDiagnostics(engine: NativeGuestEngine?, connections: UInt64) async -> NativeGuestCaptureDiagnostics {
        var result = NativeGuestCaptureDiagnostics()
        result.connectionCount = connections
        guard let engine else { return result }
        let evidence = await engine.evidence()
        let audio = engine.systemAudio?.snapshot ?? [:]
        result.statisticsStartedUptime = evidence["statisticsStartedUptime"] as? Double ?? 0
        result.statisticsCompletedUptime = evidence["statisticsCompletedUptime"] as? Double ?? 0
        result.subscriberStatsFresh = evidence["subscriberStatsFresh"] as? Bool == true
        result.videoSampleUptime = ProcessInfo.processInfo.systemUptime
        result.remoteVideoTrackCount = engine.incomingVideo.count
        if let frameWindow = engine.subscriber?.renderer.window(from: result.videoSampleUptime - 5, to: result.videoSampleUptime) {
            result.decodedCadence = .init(sourceID: "decoded", complete: frameWindow.complete, frames: frameWindow.frames,
                fps: frameWindow.fps, maximumGap: frameWindow.maximumGap, endFrameAge: frameWindow.endFrameAge)
        }
        let reports = evidence["stats"] as? [[String: Any]] ?? []
        result.selectedReceiveRelay = reports.first { $0["target"] as? String == "SUBSCRIBER" && $0["type"] as? String == "local-candidate" }?["relayProtocol"] as? String
        for report in reports where report["type"] as? String == "inbound-rtp" && report["kind"] as? String == "video" {
            func integer(_ key: String) -> Int64 { (report[key] as? NSNumber)?.int64Value ?? 0 }
            result.videoPacketsReceived += integer("packetsReceived"); result.videoBytesReceived += integer("bytesReceived")
            result.videoFramesReceived += integer("framesReceived"); result.videoFramesDecoded += integer("framesDecoded")
            result.videoPacketsLost += integer("packetsLost"); result.videoNACK += integer("nackCount")
            result.videoPLI += integer("pliCount"); result.videoFreezeCount += integer("freezeCount")
        }
        result.engineSessionID = engine.sessionID
        result.remoteParticipants = engine.connectedRemoteParticipants.count
        result.audioSnapshotUptime = audio["snapshotUptime"] as? Double ?? 0
        result.inputAvailable = audio["inputAvailable"] as? Bool == true
        result.microphoneOptIn = audio["microphoneOptIn"] as? Bool == true
        result.microphoneMuted = audio["microphoneMuted"] as? Bool == true
        result.microphoneMutedRequested = audio["microphoneMutedRequested"] as? Bool == true
        result.voiceProcessingActive = audio["voiceProcessingActive"] as? Bool == true
        result.voiceProcessingBypassed = audio["voiceProcessingBypassedActive"] as? Bool != false
        result.echoCancellationActive = audio["echoCancellationActive"] as? Bool == true
        result.outputAvailable = audio["outputAvailable"] as? Bool == true
        result.engineRunning = audio["engineRunning"] as? Bool == true
        result.inputSampleRate = audio["inputSampleRate"] as? Double ?? 0
        result.outputSampleRate = audio["outputSampleRate"] as? Double ?? 0
        result.engineStarts = audio["engineStarts"] as? Int ?? 0
        result.engineStops = audio["engineStops"] as? Int ?? 0
        if let camera = engine.cameraSnapshot {
            result.cameraPresent = true; result.cameraFrames = camera.frames
            result.cameraPTS = camera.advancingPTS; result.cameraWidth = camera.width; result.cameraHeight = camera.height
        }
        result.publisherStatsFresh = evidence["publisherStatsFresh"] as? Bool == true
        result.receivedAudioSamples = engine.mediaSnapshot.audio.samples
        result.receivedAudioEnergy = engine.mediaSnapshot.audio.energy
        result.renderedVideoFrames = engine.mediaSnapshot.render["advancingFrames"] as? Int ?? 0
        result.rawVideoCallbacks = engine.mediaSnapshot.render["frames"] as? Int ?? 0
        for report in evidence["stats"] as? [[String: Any]] ?? [] where report["type"] as? String == "outbound-rtp" {
            if report["kind"] as? String == "audio" { result.audioPacketsSent += (report["packetsSent"] as? NSNumber)?.int64Value ?? 0 }
            if report["kind"] as? String == "video" {
                result.videoFramesSent += (report["framesEncoded"] as? NSNumber)?.int64Value ?? 0
                result.encodedWidth = (report["frameWidth"] as? NSNumber)?.intValue ?? 0
                result.encodedHeight = (report["frameHeight"] as? NSNumber)?.intValue ?? 0
            }
        }
        return result
    }
}
#endif
