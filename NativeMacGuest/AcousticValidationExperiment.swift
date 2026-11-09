#if DEBUG
import AppKit
import AVFoundation
import CoreAudio
import Darwin
import Foundation
import LiveKitWebRTC
import SwiftUI

struct AcousticValidationCommand: Codable {
    enum Operation: String, Codable {
        case microphone, privateCheck, sound, processingBypass, farEnd
        case recordStart, recordStop, snapshot, playbackConfirmation, reconnect, leave
    }
    let id: UUID, generation: UUID, ownerPID: Int32, ownerID: String, operation: Operation
    var enabled: Bool?, phase: String?
}

struct AcousticValidationIPC {
    let generation: UUID, directory: URL
    let bridge: GuestAudioTestFileBridge
    private let isReceiver = ProcessInfo.processInfo.environment["ROCK_STARTUP_RECEIVER"] == "1"
    init() throws {
        guard let raw = ProcessInfo.processInfo.environment["ROCK_STARTUP_CHANNEL"], let generation = UUID(uuidString: raw),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw GuestAudioTestError.invalidCommand
        }
        self.generation = generation
        directory = support.appendingPathComponent("StartupCapture", isDirectory: true).appendingPathComponent(generation.uuidString, isDirectory: true)
        bridge = try GuestAudioTestFileBridge.current()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
    func read<T: Decodable>(_ name: String, as: T.Type) -> T? {
        if name == (isReceiver ? "acoustic-receiver-command.json" : "acoustic-command.json"), bridge.hasCommand {
            do {
                guard let data = try bridge.commandData() else { return nil }
                return try? JSONDecoder().decode(T.self, from: data)
            } catch { bridge.noteFailure(error); return nil }
        }
        let url = file(name)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attributes[.size] as? NSNumber, bytes.intValue <= 4096,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    func write(_ value: [String: Any], _ name: String) throws {
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            guard data.count <= 524_288 else { throw GuestAudioTestError.invalidCommand }
            try data.write(to: file(name), options: .atomic)
            if name == (isReceiver ? "acoustic-receiver-response.json" : "acoustic-response.json") { try bridge.mirrorResponse(data) }
            if let artifact = GuestAudioTestFileBridge.Artifact.json(named: name) { try bridge.export(data, as: artifact) }
        } catch { bridge.noteFailure(error); throw error }
    }
}

/// Typed controls layered on the existing independent synthetic fixture.
@MainActor final class AcousticFixtureControl {
    private let ipc: AcousticValidationIPC
    private let speech: GuestAudioTestSpeech
    private var lastID: UUID?
    private(set) var stopRequested = false
    private var recorder: GuestAudioTestRecording?
    private var recordID: UUID?
    private var phase: String?
    private let collectTransport = ProcessInfo.processInfo.environment["ROCK_ACOUSTIC_RTP_STATS"] == "1"
    init(engine: NativeGuestEngine) throws {
        ipc = try AcousticValidationIPC()
        if ipc.bridge.hasSpeech { speech = try GuestAudioTestSpeech(data: ipc.bridge.speechData(), source: "inherited read-only speech descriptor") }
        else {
            guard let raw = ProcessInfo.processInfo.environment["ROCK_ACOUSTIC_SPEECH_FILE"], raw.hasPrefix("/") else { throw GuestAudioTestError.invalidSpeechWAV }
            speech = try GuestAudioTestSpeech(url: URL(fileURLWithPath: raw))
        }
        guard engine.audio?.configureSpeechForTesting(speech.samples) == true else { throw GuestAudioTestError.invalidSpeechWAV }
    }
    private func snapshot(_ engine: NativeGuestEngine) -> [String: Any] {
        let media = engine.mediaSnapshot
        return ["PID": getpid(), "ownerID": ipc.generation.uuidString, "uptime": ProcessInfo.processInfo.systemUptime,
         "physicalAudioOwner": false, "source": speech.evidence, "sourceState": engine.audio?.speechStateForTesting ?? [:],
         "connected": media.connected, "failed": media.failed,
         "decodedMicrophone": StartupAudioStageStatistics.audio(media.audio),
         "recordingPhase": phase as Any? ?? NSNull()]
    }
    func poll(_ engine: NativeGuestEngine) async throws {
        try ipc.bridge.validateHealth()
        guard let command = ipc.read("acoustic-receiver-command.json", as: AcousticValidationCommand.self), command.id != lastID else { return }
        guard command.generation == ipc.generation, command.ownerPID == getpid(), command.ownerID == ipc.generation.uuidString,
              command.phase.map({ $0.count <= 100 }) ?? true else { throw GuestAudioTestError.invalidCommand }
        lastID = command.id
        let began = ProcessInfo.processInfo.systemUptime, before = snapshot(engine)
        var extra: [String: Any] = [:]
        do {
            switch command.operation {
            case .farEnd:
                guard let enabled = command.enabled, engine.audio?.setSpeechPlayingForTesting(enabled) == true else { throw GuestAudioTestError.invalidCommand }
            case .recordStart:
                guard recorder == nil, let phase = command.phase else { throw GuestAudioTestError.invalidCommand }
                if collectTransport {
                    let start = ProcessInfo.processInfo.systemUptime
                    extra["subscriberAudioAtRecordingBoundary"] = StartupAudioStageStatistics.summary(await engine.screenShareStatsForTesting(.subscriber), publisher: false)
                    extra["statisticsStartedUptime"] = start
                    extra["statisticsCompletedUptime"] = ProcessInfo.processInfo.systemUptime
                    extra["statisticsBoundary"] = "before recording admission"
                }
                let recording = GuestAudioTestRecording(); recorder = recording; recordID = command.id; self.phase = phase
                engine.setReceivedPCMObserverForTesting { [weak recording] in recording?.append($0) }
            case .recordStop:
                extra["recording"] = try await stop(engine)
                if collectTransport {
                    let start = ProcessInfo.processInfo.systemUptime
                    extra["subscriberAudioAtRecordingBoundary"] = StartupAudioStageStatistics.summary(await engine.screenShareStatsForTesting(.subscriber), publisher: false)
                    extra["statisticsStartedUptime"] = start
                    extra["statisticsCompletedUptime"] = ProcessInfo.processInfo.systemUptime
                    extra["statisticsBoundary"] = "after recording closed"
                }
            case .leave:
                stopRequested = true
            case .snapshot:
                if collectTransport {
                    extra["subscriberAudio"] = StartupAudioStageStatistics.summary(await engine.screenShareStatsForTesting(.subscriber), publisher: false)
                }
            default: throw GuestAudioTestError.invalidCommand
            }
            try ipc.write(["requestID": command.id.uuidString, "succeeded": true, "commandStartUptime": began,
                "commandEndUptime": ProcessInfo.processInfo.systemUptime, "before": before, "after": snapshot(engine), "result": extra], "acoustic-receiver-response.json")
        } catch {
            try? ipc.write(["requestID": command.id.uuidString, "succeeded": false, "error": String(describing: error),
                "before": before, "after": snapshot(engine)], "acoustic-receiver-response.json")
            throw error
        }
    }
    @discardableResult func stop(_ engine: NativeGuestEngine) async throws -> [String: Any] {
        engine.setReceivedPCMObserverForTesting(nil)
        guard let recording = recorder, let id = recordID else { return ["recording": false] }
        recorder = nil; recordID = nil
        let phase = self.phase; self.phase = nil
        let wav = ipc.file("remote-microphone-\(id.uuidString).wav")
        var result = try await recording.finish(to: wav)
        try await ipc.bridge.exportRecording(wav, as: .remoteMicrophone(id))
        result["phase"] = phase as Any? ?? NSNull()
        result["provenance"] = "independent SFU subscriber decoded primary microphone; existing track sink"
        try ipc.write(result, "remote-microphone-\(id.uuidString).json")
        return result
    }
    func cleanup(_ engine: NativeGuestEngine) async {
        _ = engine.audio?.setSpeechPlayingForTesting(false)
        _ = try? await stop(engine)
    }
    func finishExports(stopped: Bool) async -> Bool {
        var succeeded = true
        do {
            try ipc.write(["stopped": stopped, "PID": getpid(), "generation": ipc.generation.uuidString,
                "uptime": ProcessInfo.processInfo.systemUptime], "acoustic-fixture-final.json")
        } catch { succeeded = false }
        do { try await ipc.bridge.finishAndClose() } catch { succeeded = false }
        return succeeded
    }
}

extension NativeStartupReceiverProxy {
    func quiesceAcousticCommands() async {
        acousticTerminal = true
        while let pending = acousticRequest {
            let id = acousticRequestID
            _ = try? await pending.value
            if acousticRequestID == id { acousticRequest = nil; acousticRequestID = nil }
        }
    }
    func acoustic(_ operation: AcousticValidationCommand.Operation, enabled: Bool? = nil, phase: String? = nil,
                  cleanup: Bool = false) async throws -> [String: Any] {
        while let pending = acousticRequest {
            let id = acousticRequestID
            _ = try? await pending.value
            if acousticRequestID == id { acousticRequest = nil; acousticRequestID = nil }
        }
        guard !acousticTerminal || cleanup else { throw CancellationError() }
        let requestID = UUID()
        let task = Task { @MainActor in try await self.performAcoustic(operation, enabled: enabled, phase: phase) }
        acousticRequest = task; acousticRequestID = requestID
        defer { if acousticRequestID == requestID { acousticRequest = nil; acousticRequestID = nil } }
        return try await task.value
    }
    private func performAcoustic(_ operation: AcousticValidationCommand.Operation, enabled: Bool?, phase: String?) async throws -> [String: Any] {
        let ipc = try AcousticValidationIPC()
        guard let pid = ipcEvidence["receiverPID"] as? Int32 else { throw GuestAudioTestError.invalidCommand }
        let command = AcousticValidationCommand(id: UUID(), generation: ipc.generation, ownerPID: pid,
            ownerID: ipc.generation.uuidString, operation: operation, enabled: enabled, phase: phase)
        try JSONEncoder().encode(command).write(to: ipc.file("acoustic-receiver-command.json"), options: .atomic)
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let data = try? Data(contentsOf: ipc.file("acoustic-receiver-response.json")), data.count <= 131_072,
               let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any], reply["requestID"] as? String == command.id.uuidString {
                guard reply["succeeded"] as? Bool == true else { throw GuestAudioTestError.invalidCommand }
                return reply
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw GuestAudioTestError.invalidCommand
    }
}

/// Explicit, process-local diagnostic. The real desktop model owns the call;
/// no production preferences or audio-processing defaults are changed.
@MainActor final class NativeAcousticValidationExperiment {
    private static var owner: NativeAcousticValidationExperiment?
    private let ipc: AcousticValidationIPC
    private let began = ProcessInfo.processInfo.systemUptime
    private var ownerID = UUID().uuidString
    private var model: NativeDesktopMeetingModel?
    private var adapter: NativeDesktopGuestEngine?
    private var peer: NativeStartupReceiverProxy?
    private var window: NSWindow?
    private var lastID: UUID?
    private var recorder: GuestAudioTestRecording?
    private var recordID: UUID?
    private var recordPhase: String?
    private var recordBeganUptime: Double?
    private var phaseSamples: [[String: Any]] = []
    private let postCaptureRequested = ProcessInfo.processInfo.environment["ROCK_ACOUSTIC_POST_CAPTURE_TAP"] == "1"
#if ROCK_COREAUDIO_EXPERIMENT
    private var postCaptureOwner: GuestSystemAudio?
    private var postCaptureRecording: GuestPostAPMTestRecording?
#endif
    private var bypassed = false, privateChecking = false, closing = false
    private var processingMutationAttempted = false, privateCheckAttempted = false
    private var captureLifetime = GuestAudioTestCaptureLifetime()
    private var physicalPlaybackConfirmed = false
    private struct RequestedRoute {
        let inputID: UInt32, outputID: UInt32
        var evidence: [String: Any] { ["inputID": inputID, "outputID": outputID] }
    }
    private var requestedRoute: RequestedRoute?
    private var routeDevices: MacAudioDevices?
    private var confirmedRouteIdentity: String?
    private var watchdogTriggered = false
    private var watchdog: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var cleanupTask: Task<Bool, Never>?
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private var native: NativeGuestEngine? { adapter?.currentNativeEngine }

    static func startIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["ROCK_ACOUSTIC_VALIDATION"] == "1" else { return false }
        do {
            let value = try Self(); owner = value
            value.watchdog = Task { @MainActor in
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                value.watchdogTriggered = true; value.closing = true
                value.native?.setLocalMuteIntent(true, video: false)
                value.runTask?.cancel()
                await value.peer?.quiesceAcousticCommands()
                await value.runTask?.value
                let clean = await value.cleanup()
                value.emit("finished", ["completed": false, "cleanup": clean, "error": "300 second watchdog expired"])
                _ = await value.finishExports()
                exit(1)
            }
            value.runTask = Task { @MainActor in
                do {
                    try await value.run()
                    if value.watchdogTriggered { return }
                    let clean = await value.cleanup()
                    if value.watchdogTriggered { return }
                    value.watchdog?.cancel()
                    value.emit("finished", ["completed": true, "cleanup": clean, "qualityQualified": false])
                    let exported = await value.finishExports(); exit(clean && exported ? 0 : 1)
                } catch {
                    if value.watchdogTriggered { return }
                    let clean = await value.cleanup()
                    if value.watchdogTriggered { return }
                    value.watchdog?.cancel()
                    value.emit("finished", ["completed": false, "cleanup": clean, "error": String(describing: error)])
                    _ = await value.finishExports(); exit(1)
                }
            }
        } catch { print("ACOUSTIC_VALIDATION_ERROR \(error)"); fflush(stdout); exit(2) }
        return true
    }
    private init() throws { ipc = try AcousticValidationIPC() }
    private func emit(_ event: String, _ fields: [String: Any] = [:]) {
        var result = fields
        result["event"] = event; result["uptime"] = now; result["elapsedSeconds"] = now - began
        result["generation"] = ipc.generation.uuidString; result["PID"] = getpid(); result["ownerID"] = ownerID
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            print("ACOUSTIC_VALIDATION_EVENT " + String(decoding: data, as: UTF8.self)); fflush(stdout)
        }
        try? ipc.write(result, "acoustic-telemetry.json")
    }
    private func state() -> [String: Any] {
        let audio = native?.systemAudio
        // These three counters exist only on the concrete physical owner; the R4
        // shared-engine adapter deliberately does not expose them.
        let concreteAudio = audio as? GuestSystemAudio
        let routes = AcousticDefaultRoutes.snapshot()
        if physicalPlaybackConfirmed, confirmedRouteIdentity != routeIdentity(routes) { physicalPlaybackConfirmed = false }
        let input = audio?.privateInputMeterEvidence ?? [:], remote = peer?.mediaSnapshot.audio ?? .init()
        let inputFresh = (input["lastCallbackUptime"] as? Double).map { now >= $0 && now - $0 < 0.5 } ?? false
        let remoteFresh = remote.lastNonSilentUptime.map { now >= $0 && now - $0 < 0.5 } ?? false
        return ["uptime": now, "PID": getpid(), "ownerID": ownerID,
            "modelMicrophoneOn": model?.snapshot.microphoneOn ?? false, "modelSoundOn": model?.snapshot.playoutOn ?? false,
            "applicationCaptureMuted": LKRTCApplicationCaptureMuted(), "privateCheckRequested": privateChecking,
            "primaryConnectAttempted": captureLifetime.primaryConnectAttempted,
            "processingBypassRequested": bypassed, "physicalPlaybackHumanConfirmed": physicalPlaybackConfirmed,
            "physicalOwner": audio.map { String(describing: ObjectIdentifier($0)) } as Any? ?? NSNull(),
            "nativeEngine": native.map { String(describing: ObjectIdentifier($0)) } as Any? ?? NSNull(),
            "physical": audio?.snapshot ?? [:], "inputMeter": audio?.privateInputMeterEvidence ?? [:],
            "physicalPlayout": audio?.playoutMeterEvidence ?? [:],
            "liveStartupAudio": concreteAudio?.microphoneStartupEvidenceForTesting ?? [:],
            "privateGraph": concreteAudio?.privateInputGraphEvidenceForTesting ?? [:],
            "localDecodedReference": native.map { StartupAudioStageStatistics.audio($0.mediaSnapshot.audio) } ?? [:],
            "independentRemoteDecodedPCM": StartupAudioStageStatistics.audio(remote),
            "microphoneReadiness": ["physicalInputFresh": inputFresh, "remoteNonzeroFresh": remoteFresh,
                "ready": model?.snapshot.microphoneOn == true && inputFresh && remoteFresh, "speechClassified": false],
            "independentRemote": peer?.ipcEvidence ?? [:], "systemDefaultRoutes": routes,
            "requestedRoute": requestedRoute?.evidence as Any? ?? NSNull(),
            "requestedRouteMatches": requestedRoute.map { request in
                let input = routes["input"] as? [String: Any], output = routes["output"] as? [String: Any]
                return input?["deviceID"] as? UInt32 == request.inputID && output?["deviceID"] as? UInt32 == request.outputID
            } as Any? ?? NSNull(),
            "savedProfile": GuestAudioProfile.saved.rawValue,
            "savedHeadsetReady": UserDefaults.standard.bool(forKey: "nativeDesktop.headsetMuteControls"),
            "sourceRevision": ProcessInfo.processInfo.environment["ROCK_ACOUSTIC_SOURCE_REVISION"] ?? "unspecified",
            "SDKIdentity": ProcessInfo.processInfo.environment["ROCK_ACOUSTIC_SDK_IDENTITY"] ?? "unspecified"]
    }
    private func routeIdentity(_ routes: [String: Any]) -> String {
        let input = routes["input"] as? [String: Any] ?? [:], output = routes["output"] as? [String: Any] ?? [:]
        return [ownerID, String(describing: input["UID"] ?? ""), String(describing: output["UID"] ?? ""),
            String(describing: input["nominalSampleRate"] ?? ""), String(describing: output["nominalSampleRate"] ?? "")].joined(separator: "|")
    }
    /// Per-run diagnostic uses the same HAL selection model as the app UI.
    /// It never writes preferences or restores a route over a later user change.
    private func selectRequestedRoute() async throws {
        let environment = ProcessInfo.processInfo.environment
        let input = environment["ROCK_ACOUSTIC_INPUT_DEVICE_ID"], output = environment["ROCK_ACOUSTIC_OUTPUT_DEVICE_ID"]
        guard input != nil || output != nil else { return }
        guard let input, let output, let inputID = UInt32(input), let outputID = UInt32(output),
              inputID > 0, outputID > 0, String(inputID) == input, String(outputID) == output else { throw GuestAudioTestError.invalidCommand }
        let request = RequestedRoute(inputID: inputID, outputID: outputID)
        let devices = MacAudioDevices(isMac: true); routeDevices = devices; requestedRoute = request
        let before = AcousticDefaultRoutes.snapshot()
        try devices.select(outputID, for: .output); try devices.select(inputID, for: .input)
        let deadline = now + 2
        while now < deadline {
            devices.refresh()
            if devices.snapshot.inputID == inputID, devices.snapshot.outputID == outputID {
                emit("routeSelected", ["requested": request.evidence, "before": before, "applied": AcousticDefaultRoutes.snapshot(),
                    "selectionAPI": "MacAudioDevices.select; system HAL defaults", "preferencesChanged": false, "automaticRestoration": false])
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw GuestAudioTestError.invalidCommand
    }
    private func verifyRequestedRoute() throws {
        guard let request = requestedRoute else { return }
        let input: UInt32? = AcousticDefaultRoutes.property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, initial: UInt32(0))
        let output: UInt32? = AcousticDefaultRoutes.property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: UInt32(0))
        guard input == request.inputID, output == request.outputID else {
            native?.setLocalMuteIntent(true, video: false)
            emit("requestedRouteMismatch", ["requested": request.evidence, "actual": AcousticDefaultRoutes.snapshot()])
            throw GuestAudioTestError.invalidCommand
        }
    }
    private func run() async throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, GuestAudioProfile.saved == .speech else { throw GuestAudioTestError.invalidCommand }
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Bounded acoustic validation")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let peer = try NativeStartupReceiverProxy(); self.peer = peer
        emit("networkBegin")
        let invitation = try await peer.waitUntilReady(timeout: 30)
        guard let policy = GuestICEPolicy(rawValue: ProcessInfo.processInfo.environment["ROCK_MIC_TEST_ICE_POLICY"] ?? "auto") else { throw GuestAudioTestError.invalidCommand }
        let adapter = NativeDesktopGuestEngine(icePolicy: policy); self.adapter = adapter
        let model = NativeDesktopMeetingModel(destination: try .verified(invitation, engine: .guest), name: "Acoustic validation", title: "Disposable acoustic validation", engine: adapter)
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        self.window = window; window.contentView = NSHostingView(rootView: NativeDesktopMeetingView(model: model, onMini: {}))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await selectRequestedRoute()
        captureLifetime.beginPrimaryConnect()
        try await model.connect()
        try verifyRequestedRoute()
        guard let native = adapter.currentNativeEngine, !model.snapshot.microphoneOn, !model.snapshot.cameraOn,
              LKRTCApplicationCaptureMuted() == 1 else { throw GuestAudioTestError.invalidCommand }
        native.systemAudio?.setPrivateInputMeterEnabled(true)
        if postCaptureRequested {
#if ROCK_COREAUDIO_EXPERIMENT
            guard let audio = native.systemAudio else { throw GuestAudioTestError.invalidCommand }
            postCaptureOwner = audio
            guard await audio.installPostAPMDiagnosticForTesting() else { throw GuestAudioTestError.invalidCommand }
#else
            throw GuestAudioTestError.invalidCommand
#endif
        }
        let fixture = try await peer.acoustic(.snapshot)
        emit("ready", ["state": state(), "fixture": fixture, "commandFile": ipc.file("acoustic-command.json").path,
            "readySeconds": 240, "recordingMaximumSeconds": 120,
            "customCapturePostProcessingRequested": postCaptureRequested,
            "referenceProvenance": "primary received remote-track decoded PCM before HAL; physical audibility requires human confirmation",
            "latencyQualification": "callback receipt clocks do not establish acoustic sample alignment"])
        let deadline = now + 240
        var lastSample = now
        while !closing, now < deadline {
            try Task.checkCancellation()
            try ipc.bridge.validateHealth()
            if now - lastSample >= 0.1 {
                lastSample = now
                try verifyRequestedRoute()
                if recorder != nil, phaseSamples.count < 1250 {
                    let remote = peer.mediaSnapshot.audio
                    let graph = (self.native?.systemAudio as? GuestSystemAudio)?.privateInputGraphEvidenceForTesting ?? [:]
                    phaseSamples.append(["uptime": now, "modelMicrophoneOn": model.snapshot.microphoneOn,
                        "applicationCaptureMuted": LKRTCApplicationCaptureMuted(), "ownerMicrophoneMuted": self.native?.systemAudio?.snapshot["microphoneMuted"] as Any? ?? NSNull(),
                        "privateCheckRequested": privateChecking, "soundOn": model.snapshot.playoutOn,
                        "privateToken": graph["token"] as Any? ?? NSNull(), "privateGraphActive": graph["active"] as Any? ?? NSNull(),
                        "remoteSamples": remote.samples, "remoteEnergy": remote.energy,
                        "remoteLastCallbackUptime": remote.lastCallbackUptime as Any? ?? NSNull()])
                }
            }
            if let command = ipc.read("acoustic-command.json", as: AcousticValidationCommand.self), command.id != lastID {
                guard command.generation == ipc.generation, command.ownerPID == getpid(), command.ownerID == ownerID,
                      command.phase.map({ $0.count <= 100 }) ?? true else { throw GuestAudioTestError.invalidCommand }
                lastID = command.id
                try await execute(command)
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        if !closing { emit("commandWindowExpired", ["state": state()]) }
    }
    private func execute(_ command: AcousticValidationCommand) async throws {
        guard !closing, let model, let adapter, let native, let peer else { throw GuestAudioTestError.invalidCommand }
        try verifyRequestedRoute()
        let began = now, before = state()
        var extra: [String: Any] = [:]
        do {
            switch command.operation {
            case .microphone:
                guard let enabled = command.enabled, !privateChecking else { throw GuestAudioTestError.invalidCommand }
                let actionBegan = now
                if model.snapshot.microphoneOn != enabled { model.toggleMicrophone(); await model.waitForMediaActionsForTesting() }
                guard !closing, !Task.isCancelled else { throw CancellationError() }
                try verifyRequestedRoute()
                guard model.snapshot.microphoneOn == enabled, LKRTCApplicationCaptureMuted() == (enabled ? 0 : 1) else { throw GuestAudioTestError.invalidCommand }
                if enabled {
                    while now - began < 3 {
                        let input = native.systemAudio?.privateInputMeterEvidence ?? [:]
                        let inputReady = (input["lastCallbackUptime"] as? Double).map { $0 >= actionBegan && now >= $0 && now - $0 < 0.5 } ?? false
                        // User speech is requested after native input readiness;
                        // independent remote energy is a separate later fact.
                        if inputReady { break }
                        try await Task.sleep(for: .milliseconds(50))
                        guard !closing else { throw CancellationError() }
                    }
                }
                let input = native.systemAudio?.privateInputMeterEvidence ?? [:]
                let remote = peer.mediaSnapshot.audio
                extra["readiness"] = ["inputMeter": input, "remotePCM": StartupAudioStageStatistics.audio(remote),
                    "actionStartUptime": actionBegan,
                    "remoteNonzeroFreshAfterAction": remote.lastNonSilentUptime.map { $0 >= actionBegan && now >= $0 && now - $0 < 0.5 } ?? false,
                    "physicalInputFreshAfterAction": (input["lastCallbackUptime"] as? Double).map { $0 >= actionBegan && now >= $0 && now - $0 < 0.5 } ?? false,
                    "speechClassified": false]
            case .privateCheck:
                guard let enabled = command.enabled, !model.snapshot.microphoneOn, LKRTCApplicationCaptureMuted() == 1 else { throw GuestAudioTestError.invalidCommand }
                privateCheckAttempted = true
                if enabled { try await adapter.startPrivateAudioCheck() } else { try await adapter.stopPrivateAudioCheck() }
                guard !closing, !Task.isCancelled else { throw CancellationError() }
                privateChecking = enabled
                guard !model.snapshot.microphoneOn, LKRTCApplicationCaptureMuted() == 1 else { throw GuestAudioTestError.invalidCommand }
            case .sound:
                guard let enabled = command.enabled else { throw GuestAudioTestError.invalidCommand }
                if model.snapshot.playoutOn != enabled { model.togglePlayout(); await model.waitForMediaActionsForTesting() }
                guard !closing, !Task.isCancelled else { throw CancellationError() }
                guard model.snapshot.playoutOn == enabled else { throw GuestAudioTestError.invalidCommand }
            case .processingBypass:
                guard let enabled = command.enabled, let phase = command.phase, !phase.isEmpty,
                      let audio = native.systemAudio as? GuestSystemAudio else { throw GuestAudioTestError.invalidCommand }
                processingMutationAttempted = true
                guard await audio.setVoiceProcessingBypassedForTesting(enabled) else { throw GuestAudioTestError.invalidCommand }
                guard !closing, !Task.isCancelled else { throw CancellationError() }
                bypassed = enabled
                extra["processingComparisonPhase"] = phase
                extra["coupledProcessingControls"] = "VPIO AEC/NS/AGC; not AEC alone"
            case .farEnd: extra["fixture"] = try await peer.acoustic(.farEnd, enabled: command.enabled, phase: command.phase)
            case .recordStart:
                guard recorder == nil, let phase = command.phase, !phase.isEmpty else { throw GuestAudioTestError.invalidCommand }
                extra["fixture"] = try await peer.acoustic(.recordStart, phase: phase)
                guard !closing, !Task.isCancelled else { throw CancellationError() }
                let recording = GuestAudioTestRecording(); recorder = recording; recordID = command.id; recordPhase = phase
                recordBeganUptime = now; phaseSamples = []
                if postCaptureRequested {
#if ROCK_COREAUDIO_EXPERIMENT
                    guard let audio = postCaptureOwner, audio === native.systemAudio,
                          let capture = audio.beginPostAPMDiagnosticRecordingForTesting() else { throw GuestAudioTestError.invalidCommand }
                    postCaptureRecording = capture
#else
                    throw GuestAudioTestError.invalidCommand
#endif
                }
                native.setReceivedPCMObserverForTesting { [weak recording] in recording?.append($0) }
                try ipc.write(["phase": phase, "start": before, "commandStartUptime": began, "fixture": extra["fixture"]!], "phase-\(command.id.uuidString)-start.json")
            case .recordStop: extra = try await stopRecording()
            case .snapshot:
                extra["fixture"] = try await peer.acoustic(.snapshot)
                extra["transportSnapshotNativeEngine"] = String(describing: ObjectIdentifier(native))
                extra["publisherTransport"] = StartupAudioStageStatistics.summary(await native.screenShareStatsForTesting(.publisher), publisher: true)
                extra["subscriberTransport"] = StartupAudioStageStatistics.summary(await native.screenShareStatsForTesting(.subscriber), publisher: false)
            case .playbackConfirmation:
                guard let enabled = command.enabled else { throw GuestAudioTestError.invalidCommand }
                physicalPlaybackConfirmed = enabled
                confirmedRouteIdentity = enabled ? routeIdentity(AcousticDefaultRoutes.snapshot()) : nil
            case .reconnect:
                guard recorder == nil, !privateChecking, !bypassed, !postCaptureRequested else { throw GuestAudioTestError.invalidCommand }
                native.setReceivedPCMObserverForTesting(nil); native.systemAudio?.setPrivateInputMeterEnabled(false)
                if command.enabled == true {
                    // Fault only this disposable meeting's socket. The normal
                    // session recovery must preserve actual user intent.
                    let microphone = model.snapshot.microphoneOn, sound = model.snapshot.playoutOn
                    await native.interruptTransportForTesting()
                    let deadline = now + 25
                    while now < deadline {
                        guard !closing, !Task.isCancelled else { throw CancellationError() }
                        if let replacement = adapter.currentNativeEngine, replacement !== native,
                           model.snapshot.phase == .connected { break }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    guard let replacement = adapter.currentNativeEngine, replacement !== native,
                          model.snapshot.phase == .connected,
                          model.snapshot.microphoneOn == microphone, model.snapshot.playoutOn == sound,
                          native.systemAudio?.snapshot["cleanupSucceeded"] as? Bool == true else {
                        throw GuestAudioTestError.invalidCommand
                    }
                    extra["automaticRecovery"] = ["oldPhysicalOwner": native.systemAudio?.snapshot ?? [:],
                        "oldOwnerCleanupConfirmed": true,
                        "microphoneIntentPreserved": model.snapshot.microphoneOn == microphone,
                        "soundIntentPreserved": model.snapshot.playoutOn == sound]
                } else {
                    model.reconnect(); await model.waitForMediaActionsForTesting()
                }
                guard !closing, !Task.isCancelled else { throw CancellationError() }
                guard let replacement = adapter.currentNativeEngine, replacement !== native,
                      command.enabled == true || !model.snapshot.microphoneOn else { throw GuestAudioTestError.invalidCommand }
                ownerID = UUID().uuidString; physicalPlaybackConfirmed = false; replacement.systemAudio?.setPrivateInputMeterEnabled(true)
            case .leave: native.setLocalMuteIntent(true, video: false); closing = true
            }
            guard !closing || command.operation == .leave else { throw CancellationError() }
            if command.operation != .leave { try verifyRequestedRoute() }
            let after = state()
            let result: [String: Any] = ["requestID": command.id.uuidString, "operation": command.operation.rawValue,
                "phase": command.phase as Any? ?? NSNull(), "succeeded": true, "commandStartUptime": began,
                "commandEndUptime": now, "before": before, "after": after, "result": extra]
            try ipc.write(result, "acoustic-response.json")
            try ipc.write(result, "command-\(command.id.uuidString).json")
            emit("commandCompleted", ["requestID": command.id.uuidString, "operation": command.operation.rawValue, "state": after,
                "result": command.operation == .recordStop ? ["phaseReport": extra["recordStartID"] as Any? ?? NSNull()] : extra])
        } catch {
            try? ipc.write(["requestID": command.id.uuidString, "succeeded": false, "before": before,
                "after": state(), "error": String(describing: error)], "acoustic-response.json")
            throw error
        }
    }
    private func stopRecording() async throws -> [String: Any] {
        native?.setReceivedPCMObserverForTesting(nil)
        guard let recording = recorder, let id = recordID else { return ["recording": false] }
#if ROCK_COREAUDIO_EXPERIMENT
        let capture = postCaptureRecording
        postCaptureRecording = nil
        let captureEndConfirmed = capture.map { postCaptureOwner?.endPostAPMDiagnosticRecordingForTesting($0) ?? false } ?? !postCaptureRequested
        let captureOwnerStillCurrent = !postCaptureRequested || (postCaptureOwner != nil && postCaptureOwner === native?.systemAudio)
#endif
        let phase = recordPhase, samples = phaseSamples, sampleStart = recordBeganUptime ?? recording.beganUptime
        recorder = nil; recordID = nil; recordPhase = nil; recordBeganUptime = nil; phaseSamples = []
        let times = [sampleStart] + samples.compactMap { $0["uptime"] as? Double } + [now]
        let maximumSampleGap = zip(times, times.dropFirst()).map { $1 - $0 }.max() ?? 0
        let end = state()
        var remote: [String: Any] = [:], remoteStopConfirmed = false
        do { remote = try await peer?.acoustic(.recordStop, phase: phase, cleanup: closing) ?? [:]; remoteStopConfirmed = true }
        catch { remote = ["stopConfirmed": false, "error": String(describing: error)] }
        let wav = ipc.file("local-decoded-reference-\(id.uuidString).wav")
        var local = try await recording.finish(to: wav)
        try await ipc.bridge.exportRecording(wav, as: .localReference(id))
        local["provenance"] = "primary subscriber decoded far-end track; pre-HAL, not physical acoustic output"
        var result: [String: Any] = ["phase": phase as Any? ?? NSNull(), "recordStartID": id.uuidString,
            "localReference": local, "independentRemote": remote, "end": end, "gateSamples": samples,
            "qualityQualified": false, "remoteStopConfirmed": remoteStopConfirmed, "humanPhysicalPlaybackConfirmed": physicalPlaybackConfirmed,
            "gateSampling": ["provenance": "opportunistic MainActor polling; pauses during awaited commands; cannot prove whole-transaction gates or continuity",
                "nominalIntervalSeconds": 0.1, "maximumGapSeconds": maximumSampleGap, "sampleCapReached": samples.count >= 1250,
                "wholeTransactionProof": false, "transientRouteObservationSupported": false],
            "alignment": "separate callback receipt clocks; infer sample alignment from known fixture waveform, not IPC completion"]
        result["customCapturePostProcessingRequested"] = postCaptureRequested
#if ROCK_COREAUDIO_EXPERIMENT
        if let capture {
            let captureWAV = ipc.file(GuestAudioTestFileBridge.Artifact.customCapturePostProcessing(id).name)
            var captured = try await capture.finish(to: captureWAV)
            captured["recordingAdmissionClosedAndDrained"] = captureEndConfirmed
            captured["ownerStillCurrent"] = captureOwnerStillCurrent
            captured["coldStartupTimingQualified"] = false
            result["customCapturePostProcessing"] = captured
            try await ipc.bridge.exportRecording(captureWAV, as: .customCapturePostProcessing(id))
        }
#endif
        try ipc.write(result, "phase-\(id.uuidString)-end.json")
        guard remoteStopConfirmed else { throw GuestAudioTestError.invalidCommand }
#if ROCK_COREAUDIO_EXPERIMENT
        if postCaptureRequested {
            guard capture != nil, captureEndConfirmed, captureOwnerStillCurrent,
                  (result["customCapturePostProcessing"] as? [String: Any])?["quantitativeEligible"] as? Bool == true else { throw GuestAudioTestError.invalidCommand }
        }
#endif
        return result
    }
    private func cleanup() async -> Bool {
        if let cleanupTask { return await cleanupTask.value }
        closing = true
        native?.setLocalMuteIntent(true, video: false)
        let task = Task { @MainActor in await self.cleanupOnce() }; cleanupTask = task
        return await task.value
    }
    private func finishExports() async -> Bool {
        do { try await ipc.bridge.finishAndClose(); return true }
        catch { print("ACOUSTIC_EXPORT_ERROR \(error)"); fflush(stdout); return false }
    }
    private func cleanupOnce() async -> Bool {
        await peer?.quiesceAcousticCommands()
        if let model, model.snapshot.microphoneOn { model.toggleMicrophone(); await model.waitForMediaActionsForTesting() }
        var privateStopped = true
        if privateCheckAttempted {
            do { try await adapter?.stopPrivateAudioCheck() } catch { privateStopped = false }
            privateChecking = false
        }
        var restored = true
        if processingMutationAttempted { restored = await (native?.systemAudio as? GuestSystemAudio)?.setVoiceProcessingBypassedForTesting(false) ?? false; bypassed = false }
        _ = try? await peer?.acoustic(.farEnd, enabled: false, cleanup: true)
        _ = try? await stopRecording()
        native?.setReceivedPCMObserverForTesting(nil); native?.systemAudio?.setPrivateInputMeterEnabled(false)
        let postCaptureDetached: Bool
#if ROCK_COREAUDIO_EXPERIMENT
        if let owner = postCaptureOwner {
            postCaptureDetached = await owner.detachPostAPMDiagnosticForTesting()
            if postCaptureDetached { postCaptureOwner = nil }
        } else { postCaptureDetached = true }
#else
        postCaptureDetached = true
#endif
        let primary = await model?.leave() ?? true
        let remote = await peer?.leave() ?? true
        window?.contentView = nil; window?.orderOut(nil); window = nil
        let captureMuted = LKRTCApplicationCaptureMuted(), gateStatus = captureLifetime.gateStatus(rawValue: captureMuted)
        emit("cleanup", ["primaryStopped": primary, "fixtureStopped": remote, "processingRestored": restored,
            "privateStopped": privateStopped, "customCapturePostProcessingDetached": postCaptureDetached,
            "captureMuted": captureMuted, "captureGateStatus": gateStatus.rawValue,
            "primaryConnectAttempted": captureLifetime.primaryConnectAttempted, "state": state()])
        model = nil; adapter = nil; peer = nil
        return primary && remote && restored && privateStopped && postCaptureDetached && gateStatus != .unconfirmed
    }
}

/// Read-only system defaults. Engine snapshot rates remain separately labelled;
/// a default route query alone does not prove the SDK's current device binding.
private enum AcousticDefaultRoutes {
    static func property<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                            element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain, initial: T) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value = initial, size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              size == UInt32(MemoryLayout<T>.size) else { return nil }
        return value
    }
    static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        // CoreAudio transfers +1 ownership for these CFString properties.
        var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              size == UInt32(MemoryLayout<Unmanaged<CFString>?>.size), let value else { return nil }
        return value.takeRetainedValue() as String
    }
    static func snapshot() -> [String: Any] {
        func device(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> [String: Any] {
            guard let id = property(AudioObjectID(kAudioObjectSystemObject), selector, initial: AudioDeviceID(0)), id != 0 else { return ["available": false] }
            let name = stringProperty(id, kAudioObjectPropertyName), uid = stringProperty(id, kAudioDevicePropertyDeviceUID)
            let transport: UInt32? = property(id, kAudioDevicePropertyTransportType, initial: UInt32(0))
            let rate: Double? = property(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0))
            var result: [String: Any] = ["deviceID": id, "name": name as Any? ?? NSNull(), "UID": uid as Any? ?? NSNull(),
                "transport": transport as Any? ?? NSNull(), "nominalSampleRate": rate as Any? ?? NSNull()]
            for element: UInt32 in [0, 1, 2] {
                let volume: Float? = property(id, kAudioDevicePropertyVolumeScalar, scope: scope, element: element, initial: Float(0))
                let muted: UInt32? = property(id, kAudioDevicePropertyMute, scope: scope, element: element, initial: UInt32(0))
                result["volumeScalar\(element)"] = volume as Any? ?? NSNull()
                result["muted\(element)"] = muted as Any? ?? NSNull()
            }
            return result
        }
        return ["uptime": ProcessInfo.processInfo.systemUptime, "bindingProof": false,
            "input": device(kAudioHardwarePropertyDefaultInputDevice, kAudioDevicePropertyScopeInput),
            "output": device(kAudioHardwarePropertyDefaultOutputDevice, kAudioDevicePropertyScopeOutput)]
    }
}
#endif
