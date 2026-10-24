import Foundation
import AppKit
import AVFoundation
import LiveKitWebRTC
import Darwin

@main
struct NativeGuestProbe {
    @MainActor static func main() async {
        do {
            var args = Array(CommandLine.arguments.dropFirst())
            if args.isEmpty, let bundled = Bundle.main.object(forInfoDictionaryKey: "RockNativeGuestArguments") as? [String] {
                args = bundled
                if let log = Bundle.main.object(forInfoDictionaryKey: "RockNativeGuestLogPath") as? String {
                    let fd = Darwin.open(log, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
                    guard fd >= 0 else { throw UsageError.invalidArguments }
                    dup2(fd, STDOUT_FILENO); dup2(fd, STDERR_FILENO); Darwin.close(fd)
                }
                _ = NSApplication.shared
            }
            probeLog("process-start", ["nativeMacOS": !ProcessInfo.processInfo.isiOSAppOnMac])
            if args == ["--self-test"] { try selfTest(); return }
            func option(_ flag: String) -> String? {
                guard let index = args.firstIndex(of: flag), args.indices.contains(index+1) else { return nil }
                return args[index+1]
            }
            if let originText = option("--create-room"), let origin = URL(string: originText),
               let output = option("--output") {
                let invitation = try await GuestBootstrap.createDisposable(origin: origin)
                let file = URL(fileURLWithPath: output)
                try Data(invitation.invitationURL.absoluteString.utf8).write(to: file, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                probeLog("disposable-room-created", ["invitationSaved": true]); return
            }
            guard let path = option("--invite-file") else {
                throw UsageError.invalidArguments
            }
            let seconds = option("--seconds").flatMap(UInt64.init) ?? 30
            let cycles = option("--cycles").flatMap(Int.init) ?? 1
            guard (1...5).contains(cycles), cycles == 1 || args.contains("--toggle") else { throw UsageError.invalidArguments }
            guard (5...(args.contains("--companion-peer") ? 480 : 120)).contains(seconds) else { throw UsageError.invalidArguments }
            // Independent of actor/capture/RTC queues. A hung diagnostic must release
            // its process rather than leave a physical camera or guest client running.
            Darwin.signal(SIGALRM, SIG_DFL)
            Darwin.alarm(args.contains("--duplex") ? (args.contains("--duplex-soak-seconds") ? 290 : 240) : UInt32(max(seconds, UInt64(cycles * 30)) + 90))
            let codec = option("--codec") ?? "h264"
            guard ["h264", "vp8", "vp9"].contains(codec) else { throw UsageError.invalidArguments }
            guard (!args.contains("--camera") && !args.contains("--toggle")) || args.contains("--pair") else { throw UsageError.invalidArguments }
            if args.contains("--start-video-muted") {
                guard args.contains("--pair"), !args.contains("--camera"), !args.contains("--toggle"), !args.contains("--real-audio") else { throw UsageError.invalidArguments }
            }
            guard !args.contains("--real-playout") || args.contains("--pair") else { throw UsageError.invalidArguments }
            guard !args.contains("--reconnect") || args.contains("--pair") else { throw UsageError.invalidArguments }
            guard !args.contains("--real-audio") || (args.contains("--pair") && !args.contains("--toggle") && !args.contains("--reaction")) else { throw UsageError.invalidArguments }
            if args.contains("--reaction") {
                guard args.contains("--pair"), args.contains("--camera"), !args.contains("--toggle"), seconds >= 15 else { throw UsageError.invalidArguments }
            }
            if args.contains("--camera") {
                probeLog("camera-permission", ["status": AVCaptureDevice.authorizationStatus(for: .video).rawValue])
            }
            let invitation = try GuestInvitation.parse(String(contentsOfFile: path, encoding: .utf8))
            if args.contains("--companion-peer") {
                guard let directory = option("--evidence-directory"), args.count == (option("--companion-ice") == nil ? 7 : 9),
                      let peerPolicy = GuestICEPolicy(rawValue: option("--companion-ice") ?? "auto") else { throw UsageError.invalidArguments }
                _ = LKRTCInitializeSSL()
                try await GuestCompanionPeer.run(invitation, directory: URL(fileURLWithPath: directory), seconds: seconds, icePolicy: peerPolicy, monitorSender: option("--companion-ice") != nil)
                Darwin.alarm(0); return
            }
            let duplex = args.contains("--duplex")
            let reconnectCycles: Int
            if args.contains("--duplex-reconnect-cycles") {
                guard duplex, let value = option("--duplex-reconnect-cycles").flatMap(Int.init),
                      (1...3).contains(value), !args.contains("--duplex-aec-comparison") else { throw UsageError.invalidArguments }
                reconnectCycles = value
            } else { reconnectCycles = 1 }
            let icePolicy: GuestICEPolicy
            if args.contains("--duplex-ice") {
                guard duplex, let value = option("--duplex-ice").flatMap(GuestICEPolicy.init(rawValue:)) else { throw UsageError.invalidArguments }
                icePolicy = value
            } else if args.contains("--pair-ice") {
                guard !duplex, args.contains("--pair"), let value = option("--pair-ice").flatMap(GuestICEPolicy.init(rawValue:)) else { throw UsageError.invalidArguments }
                icePolicy = value
            } else { icePolicy = .automatic }
            let soakSeconds: Int
            if args.contains("--duplex-soak-seconds") {
                guard duplex, let value = option("--duplex-soak-seconds").flatMap(Int.init),
                      (40...120).contains(value), value % 20 == 0, reconnectCycles <= 2,
                      !args.contains("--duplex-aec-comparison") else { throw UsageError.invalidArguments }
                soakSeconds = value
            } else { soakSeconds = 0 }
            guard duplex || !args.contains("--duplex-aec-comparison") else { throw UsageError.invalidArguments }
            if duplex {
                guard !["--camera", "--toggle", "--reaction", "--real-audio", "--real-playout", "--reconnect", "--fixture-bypass-voice-processing", "--expect-alone", "--save-frame"].contains(where: args.contains) else { throw UsageError.invalidArguments }
            }
            let eventLogDirectory: URL?
            if args.contains("--rtc-event-log-directory") {
                guard duplex, let directory = option("--rtc-event-log-directory"), !directory.isEmpty,
                      !directory.hasPrefix("--") else { throw UsageError.invalidArguments }
                eventLogDirectory = URL(fileURLWithPath: directory, isDirectory: true)
            } else { eventLogDirectory = nil }
            let realMicrophone = args.contains("--real-audio") || duplex, realPlayout = args.contains("--real-playout")
            let fixtureBypass = args.contains("--fixture-bypass-voice-processing")
            guard !fixtureBypass || realMicrophone else { throw UsageError.invalidArguments }
            guard !(realMicrophone && realPlayout && args.contains("--pair")) else { throw UsageError.invalidArguments }
            if realMicrophone {
                guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else { throw UsageError.invalidArguments }
                let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                probeLog("microphone-permission", ["status": microphoneStatus.rawValue])
                if microphoneStatus == .notDetermined {
                    let granted: Bool = try await guestAwait(timeout: 30) { done in
                        AVCaptureDevice.requestAccess(for: .audio) { done(.success($0)) }
                    }
                    probeLog("microphone-permission-result", ["granted": granted])
                    guard granted else { throw GuestSystemAudioError.microphonePermissionRequired }
                }
            }
            if realMicrophone, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                throw GuestSystemAudioError.microphonePermissionRequired
            }
            if let url = eventLogDirectory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                GuestPeer.diagnosticEventLogDirectory = url
            }
            _ = LKRTCInitializeSSL()
            if duplex {
                try await GuestDuplexProbe.run(invitation, seconds: seconds, codec: codec, compareProcessing: args.contains("--duplex-aec-comparison"), reconnectCycles: reconnectCycles, soakSeconds: soakSeconds, icePolicy: icePolicy)
                Darwin.alarm(0)
                return
            }
            let receiverSession = GuestSession(makeEngine: {
                let physical = realPlayout || (realMicrophone && !args.contains("--pair"))
                let owner = physical ? try await GuestSystemAudio.create(microphoneEnabled: realMicrophone, playoutEnabled: true) : nil
                return NativeGuestEngine(label: "Native guest receiver", systemAudio: owner, icePolicy: icePolicy)
            })
            let senderSession: GuestSession? = args.contains("--pair") ? GuestSession(makeEngine: {
                let owner = realMicrophone ? try await GuestSystemAudio.create(microphoneEnabled: true, playoutEnabled: true, voiceProcessingEnabled: !fixtureBypass) : nil
                return NativeGuestEngine(label: "Native guest sender", systemAudio: owner, icePolicy: icePolicy)
            }) : nil
            var receiver: NativeGuestEngine? { receiverSession.engine }
            var sender: NativeGuestEngine? { senderSession?.engine }

            do {
                try await receiverSession.connect(invitation, publish: false, codec: codec, camera: false)
                if args.contains("--expect-alone"), receiver?.admittedParticipants != 1 { throw GuestEngineError.mediaMissing }
                if let senderSession {
                    try await senderSession.connect(invitation, publish: true, codec: codec, camera: args.contains("--camera"),
                                                    initialVideoMuted: args.contains("--start-video-muted"))
                }
                if args.contains("--start-video-muted"), let sender {
                    try await liveWindow(try requireEngine(receiverSession), phase: "initial-video-muted", seconds: 4, videoExpected: false)
                    let initial = await sender.evidence()
                    guard (initial["localVideo"] as? [String: Any])?["generatedFrames"] as? Int == 0 else { throw GuestEngineError.mediaMissing }
                    try await senderSession!.mute(false, video: true)
                    try await liveWindow(try requireEngine(receiverSession), phase: "initial-video-resumed", seconds: 4)
                } else if args.contains("--toggle"), let sender {
                  for cycle in 1...cycles {
                    try await liveWindow(try requireEngine(receiverSession), phase: "initial", seconds: 4)
                    try await senderSession!.mute(true)
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    try await liveWindow(try requireEngine(receiverSession), phase: "audio-muted", seconds: 3, audioExpected: false)
                    try await senderSession!.mute(false)
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    try await liveWindow(try requireEngine(receiverSession), phase: "audio-resumed", seconds: 3)
                    let stableIdentity = sender.publicationIdentity
                    let beforeVideo = await sender.evidence()
                    let beforeKeyframes = keyframes(beforeVideo, outbound: true)
                    probeLog("before-video-toggle-sender", beforeVideo)
                    probeLog("before-video-toggle-receiver", try await requireEngine(receiverSession).evidence())
                    try await senderSession!.mute(true, video: true)
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    try await liveWindow(try requireEngine(receiverSession), phase: "video-muted", seconds: 3, videoExpected: false)
                    try await senderSession!.mute(false, video: true)
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    try await liveWindow(try requireEngine(receiverSession), phase: "video-resumed", seconds: 3)
                    let afterVideo = await sender.evidence()
                    let freshKeyframes = keyframes(afterVideo, outbound: true) - beforeKeyframes
                    let samePublication = sender.publicationIdentity == stableIdentity
                    probeLog("video-resume-evidence", ["cycle": cycle, "samePublicationSenderMID": samePublication,
                        "newEncodedKeyframes": freshKeyframes])
                    guard samePublication, freshKeyframes > 0 else { throw GuestEngineError.mediaMissing }
                  }
                } else if args.contains("--reaction"), let sender, args.contains("--camera"), seconds >= 15 {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    let requested = await sender.requestCameraReaction()
                    probeLog("reaction-request", ["issued": requested])
                    guard requested else { throw GuestEngineError.mediaMissing }
                    for index in 1...3 {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        if let path = option("--save-frame") {
                            let url = URL(fileURLWithPath: path).deletingPathExtension()
                            try receiver?.subscriber?.renderer.savePNG(url.path + "-reaction-\(index).png")
                        }
                    }
                    guard sender.observedCameraReaction else { throw GuestEngineError.mediaMissing }
                    try await Task.sleep(nanoseconds: (seconds - 8) * 1_000_000_000)
                } else if realMicrophone, let sender {
                    try await microphoneWindow(sender: sender, receiver: try requireEngine(receiverSession), seconds: min(seconds, 20), camera: args.contains("--camera"))
                    try await senderSession!.mute(true)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    try await microphoneWindow(sender: sender, receiver: try requireEngine(receiverSession), seconds: 2,
                        camera: args.contains("--camera"), audioExpected: false)
                    try await senderSession!.mute(false)
                    try await microphoneWindow(sender: sender, receiver: try requireEngine(receiverSession), seconds: 5, camera: args.contains("--camera"))
                } else {
                    try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                }
                if args.contains("--reconnect") {
                    guard let senderSession else { throw UsageError.invalidArguments }
                    try await receiverSession.reconnectForTesting()
                    if realMicrophone {
                        try await microphoneWindow(sender: try requireEngine(senderSession), receiver: try requireEngine(receiverSession), seconds: 5, camera: args.contains("--camera"))
                    } else {
                        try await liveWindow(try requireEngine(receiverSession), phase: "receiver-reconnected", seconds: 3)
                    }
                    try await senderSession.mute(true)
                    try await senderSession.mute(true, video: true)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    try await senderSession.reconnectForTesting()
                    try await liveWindow(try requireEngine(receiverSession), phase: "sender-reconnected-muted", seconds: 3,
                        audioExpected: false, videoExpected: false)
                    try await senderSession.mute(false)
                    try await senderSession.mute(false, video: true)
                    if realMicrophone {
                        try await microphoneWindow(sender: try requireEngine(senderSession), receiver: try requireEngine(receiverSession), seconds: 5, camera: args.contains("--camera"))
                    } else {
                        try await liveWindow(try requireEngine(receiverSession), phase: "sender-reconnected-unmuted", seconds: 3)
                    }
                    probeLog("reconnect-evidence", ["receiverConnections": receiverSession.connectionCount,
                        "senderConnections": senderSession.connectionCount, "receiverAttempts": receiverSession.recoveryAttempts,
                        "senderAttempts": senderSession.recoveryAttempts])
                }
                if let error = receiverSession.failure ?? senderSession?.failure ?? receiver?.failure ?? sender?.failure { throw error }
                if (args.contains("--require-media") || sender != nil) && !realMicrophone {
                    try await liveWindow(try requireEngine(receiverSession), phase: "final", seconds: 3)
                }
                if let image = option("--save-frame") { try receiver?.subscriber?.renderer.savePNG(image) }
                let evidence = try await requireEngine(receiverSession).evidence()
                if realPlayout {
                    let hardware = evidence["physicalAudio"] as? [String: Any] ?? [:]
                    guard evidence["physicalAudioSnapshotFresh"] as? Bool == true,
                          hardware["outputRunning"] as? Bool == true,
                          (hardware["outputSampleRate"] as? NSNumber)?.doubleValue ?? 0 >= 44_100,
                          hardware["inputRunning"] as? Bool == false else { throw GuestEngineError.mediaMissing }
                }
                probeLog("receiver-evidence", evidence)
                if let sender { probeLog("sender-evidence", await sender.evidence()) }
                if (args.contains("--require-media") || sender != nil) && !realMicrophone {
                    let render = evidence["render"] as? [String: Any] ?? [:]
                    guard (render["advancingFrames"] as? Int ?? 0) > 10,
                          (render["pixelChanges"] as? Int ?? 0) > 5,
                          (evidence["decodedAudioRMS"] as? Double ?? 0) > 0.001 else {
                        throw GuestEngineError.mediaMissing
                    }
                }
                let senderStopped = await senderSession?.leave() ?? true
                let receiverStopped = await receiverSession.leave()
                guard senderStopped && receiverStopped else { throw GuestEngineError.disconnected }
                probeLog("prototype-pass", ["pair": senderSession != nil, "codecRequested": codec,
                    "physicalMicrophoneVerified": realMicrophone, "physicalPlayoutVerified": realPlayout,
                    "voiceProcessingBypassedForAcousticFixture": fixtureBypass])
                Darwin.alarm(0)
            } catch {
                if let receiver { probeLog("failure-receiver-evidence", await receiver.evidence()) }
                if let sender { probeLog("failure-sender-evidence", await sender.evidence()) }
                await senderSession?.leave(); await receiverSession.leave()
                throw error
            }
        } catch {
            // Localized transport errors are sanitized by their concrete error type.
            var detail = String(describing: type(of: error))
            if let typed = error as? GuestTransportError { detail = typed.errorDescription ?? detail }
            if let typed = error as? GuestBootstrapError { detail = typed.errorDescription ?? detail }
            if let typed = error as? GuestEngineError { detail = String(describing: typed) }
            if let typed = error as? GuestSessionError { detail = String(describing: typed) }
            if let typed = error as? GuestSystemAudioError { detail = String(describing: typed) }
            if let typed = error as? GuestCameraError { detail = String(describing: typed) }
            probeLog("prototype-failed", ["detail": detail])
            exit(1)
        }
    }

    @MainActor static func microphoneWindow(sender: NativeGuestEngine, receiver: NativeGuestEngine, seconds: UInt64,
        camera: Bool, audioExpected: Bool = true) async throws {
        // A real acoustic fixture is supplied independently (speech or a speaker).
        // This cannot pass on signaling/ADM setup alone: microphone PCM must
        // reach the independent receiver. Local audio AddSink is a no-op in
        // this WebRTC revision, so it cannot be used as capture evidence.
        let beforeOutput = receiver.mediaSnapshot
        let beforeCapture = sender.cameraSnapshot?.advancingPTS
        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        let afterOutput = receiver.mediaSnapshot
        let remote = afterOutput.audio.since(beforeOutput.audio)
        let videoChanges = afterOutput.changes(since: beforeOutput)
        let capturedFrames = beforeCapture.flatMap { before in sender.cameraSnapshot.map { $0.advancingPTS - before } }
        let videoExpectation: GuestMediaSnapshot.VideoExpectation = camera ? .nativeCamera(capturedFrames: capturedFrames) : .movingPattern
        let evidence = await sender.evidence()
        let physical = evidence["physicalAudio"] as? [String: Any] ?? [:]
        // A voice-processed acoustic fixture has variable level (and intentional
        // echo cancellation). Require energy above the mute ceiling, not the
        // much louder synthetic-tone floor used by liveWindow.
        let pass = remote.samples > 48_000 && (audioExpected ? remote.rms > 0.0002 : remote.rms < 0.0002) &&
            evidence["physicalAudioSnapshotFresh"] as? Bool == true &&
            physical["inputRunning"] as? Bool == true && physical["microphoneMuted"] as? Bool == !audioExpected &&
            afterOutput.hasFreshVideo(since: beforeOutput, expectation: videoExpectation) &&
            sender.mediaSnapshot.connected && sender.failure == nil
        probeLog("physical-microphone-window", ["receivedSamples": remote.samples, "receivedRMS": remote.rms,
            "physicalInputRunning": physical["inputRunning"] as? Bool ?? false, "pixelChanges": videoChanges,
            "audioExpected": audioExpected, "nativeCamera": camera,
            "advancingFrames": afterOutput.advancingFrames(since: beforeOutput),
            "capturedFrames": capturedFrames as Any? ?? NSNull(), "pass": pass])
        guard pass else { throw GuestEngineError.mediaMissing }
    }

    static func keyframes(_ evidence: [String: Any], outbound: Bool) -> Int {
        (evidence["stats"] as? [[String: Any]] ?? []).filter {
            $0["type"] as? String == (outbound ? "outbound-rtp" : "inbound-rtp") && $0["kind"] as? String == "video"
        }.reduce(0) { $0 + (($1[outbound ? "keyFramesEncoded" : "keyFramesDecoded"] as? NSNumber)?.intValue ?? 0) }
    }

    @MainActor static func requireEngine(_ session: GuestSession) throws -> NativeGuestEngine {
        guard let engine = session.engine else { throw session.failure ?? GuestTransportError.notConnected }
        return engine
    }

    @MainActor static func liveWindow(_ engine: NativeGuestEngine, phase: String, seconds: UInt64,
        audioExpected: Bool = true, videoExpected: Bool = true) async throws {
        let before = engine.mediaSnapshot
        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        let after = engine.mediaSnapshot
        let pcm = after.audio.since(before.audio)
        let changes = after.changes(since: before)
        let pass = after.connected && !after.failed && (!audioExpected || pcm.samples > 48_000) &&
            (audioExpected ? pcm.rms > 0.001 : pcm.rms < 0.0002) &&
            (videoExpected ? changes > 5 : after.hasQuiescentVideo(since: before))
        probeLog("media-window", ["phase": phase, "rms": pcm.rms, "samples": pcm.samples,
            "pixelChanges": changes, "frames": (after.render["frames"] as? Int ?? 0) - (before.render["frames"] as? Int ?? 0),
            "advancingFrames": (after.render["advancingFrames"] as? Int ?? 0) - (before.render["advancingFrames"] as? Int ?? 0),
            "connected": after.connected, "pass": pass])
        guard pass else { throw GuestEngineError.mediaMissing }
    }

    enum UsageError: Error { case invalidArguments, testFailure }

    static func selfTest() throws {
        let parsed = try GuestInvitation(url: URL(string: "https://example.test:8443/calls/a%2Db?psw=OAMDFgFVV0VdEwQAXkFAVlIZGQ")!)
        guard parsed.roomID == "a-b", parsed.password == "pass1234", parsed.origin.port == 8443 else { throw UsageError.testFailure }
        for text in ["http://example.test/calls/x", "https://u:p@example.test/calls/x", "https://example.test/calls/a%2Fb",
                     "https://example.test/calls/x?psw=a&psw=b", "https://example.test/calls/x#secret"] {
            do { _ = try GuestInvitation.parse(text); throw UsageError.testFailure }
            catch is GuestBootstrapError {}
        }
        guard GuestTransport.isResponse(["requestId": "1", "event": "join-response"], requestID: "1", event: "join"),
              GuestTransport.isResponse(["requestId": "1", "event": "error"], requestID: "1", event: "join"),
              !GuestTransport.isResponse(["requestId": "1", "event": "joined"], requestID: "1", event: "join"),
              !GuestTransport.isResponse(["requestId": "2", "event": "join-response"], requestID: "1", event: "join") else {
            throw UsageError.testFailure
        }
        probeLog("self-test-pass", ["malformedInvitationsRejected": 5, "correlationCases": 4])
    }
}
