#if DEBUG
import AppKit
import AVFoundation
import Darwin
import LiveKitWebRTC
import SwiftUI

/// Opt-in real desktop meeting diagnostic. Preserves all saved preferences.
@MainActor final class NativeMicrophoneActivationExperiment {
    private static var owner: NativeMicrophoneActivationExperiment?
    private let began = ProcessInfo.processInfo.systemUptime
    private var window: NSWindow?
    private var model: NativeDesktopMeetingModel?
    private var adapter: NativeDesktopGuestEngine?
    private var peer: NativeStartupReceiverProxy?
    private var logger: LKRTCFileLogger?
    private var logDirectory: URL?
    private var monitor: Task<Void, Never>?
    private let startupStagesEnabled = ProcessInfo.processInfo.environment["ROCK_MIC_STARTUP_STAGES"] == "1"
    private let noDemandSeamWarmup = ProcessInfo.processInfo.environment["ROCK_MIC_NO_DEMAND_SEAMS"] == "1"
    private let rawStartSupersessionEnabled = ProcessInfo.processInfo.environment["ROCK_MIC_RAW_START_TRACK_SUPERSESSION"] == "1"
    #if ROCK_COREAUDIO_DUPLEX_R6
    private var rawStartSupersessionTask: Task<Void, Never>?
    private var rawStartSupersessionAttempt: StartupRawOutputSupersession.Attempt?
    private var rawStartSupersessionReported = false
    #endif
    private var startupStageTask: Task<Void, Never>?
    private var startupTimeline: StartupTimeline?
    private var watchdog: Task<Void, Never>?
    private var cleanupTask: Task<Bool, Never>?
    private var windows: [String: ReceiveWindow] = [:]
    private var maximumMainInterval = 0.0
    private var mainGapStart = 0.0, mainGapEnd = 0.0
    private var acceptance = true
    private weak var releasedModel: NativeDesktopMeetingModel?
    private weak var releasedAdapter: NativeDesktopGuestEngine?
    private weak var releasedNative: NativeGuestEngine?
    private weak var releasedPeer: NativeStartupReceiverProxy?
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    static func startIfRequested() -> Bool {
        if let raw = ProcessInfo.processInfo.environment["ROCK_MIC_EXPORT"], let channel = UUID(uuidString: raw),
           let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let path = support.appendingPathComponent("StartupCapture").appendingPathComponent(channel.uuidString).appendingPathComponent("rtc-logs/rtc.log")
            do {
                let data = try Data(contentsOf: path); guard data.count <= 1_048_576 else { exit(2) }
                print("MICROPHONE_LOG_EXPORT " + data.base64EncodedString()); fflush(stdout); exit(0)
            } catch { print("MICROPHONE_LOG_EXPORT_FAILED"); fflush(stdout); exit(2) }
        }
        guard ProcessInfo.processInfo.environment["ROCK_MIC_ACTIVATION"] == "1" else { return false }
        let value = Self(); owner = value
        value.watchdog = Task { @MainActor [weak value] in
            do { try await Task.sleep(for: .seconds(150)) } catch { return }
            guard let value else { return }
            let clean = await value.cleanup()
            value.emit("finished", ["completed": false, "acceptance": false, "cleanup": clean, "error": "150 second lifetime exceeded"])
            exit(1)
        }
        Task { @MainActor in
            do {
                try await value.run(); value.watchdog?.cancel(); value.watchdog = nil
                value.emit("finished", ["completed": true, "acceptance": value.acceptance]); exit(0)
            } catch {
                value.watchdog?.cancel(); value.watchdog = nil
                let clean = await value.cleanup()
                value.emit("finished", ["completed": false, "acceptance": false, "cleanup": clean, "error": String(describing: error)])
                exit(1)
            }
        }
        return true
    }
    private func resources() -> [String: Any] {
        var usage = rusage_info_v6(), timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
        }
        let ticks = usage.ri_user_time + usage.ri_system_time
        return ["result": result, "cpuTicks": ticks,
            "cpuSeconds": Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9,
            "timeNumer": timebase.numer, "timeDenom": timebase.denom, "energyNJ": usage.ri_energy_nj,
            "footprint": usage.ri_phys_footprint, "resident": usage.ri_resident_size,
            "wakeups": usage.ri_interrupt_wkups, "thermal": ProcessInfo.processInfo.thermalState.rawValue]
    }
    private func emit(_ event: String, _ fields: [String: Any] = [:]) {
        var value = fields; value["event"] = event; value["uptime"] = now
        if noDemandSeamWarmup {
            value["coldStartupTimingQualified"] = false
            value["startupTimingExclusionReason"] = "pre-network real factory seam validation"
        }
        if rawStartSupersessionEnabled {
            value["coldStartupTimingQualified"] = false
            value["startupTimingExclusionReason"] = noDemandSeamWarmup ?
                "pre-network seam validation; controlled raw-start track invalidation" : "controlled raw-start track invalidation"
        }
        value["elapsed"] = now - began; value["resources"] = resources()
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            print("MICROPHONE_ACTIVATION_EVENT " + String(decoding: data, as: UTF8.self)); fflush(stdout)
        }
    }
    private func idle(_ phase: String) async throws {
        let cameraPostLeave = (ProcessInfo.processInfo.environment["ROCK_CAMERA_PROFILE_WINDOWS"] == "1" ||
            ProcessInfo.processInfo.environment["ROCK_MIC_PROFILE_WINDOWS"] == "1") && phase == "afterMeetingLeave"
        if ProcessInfo.processInfo.environment["ROCK_MIC_SKIP_IDLE"] == "1", !cameraPostLeave {
            emit("idleSkipped", ["phase": phase, "energyAcceptance": false]); return
        }
        emit("idleBegin", ["phase": phase]); try await Task.sleep(for: .seconds(2))
        let start = resources(), uptime = now
        try await Task.sleep(for: .seconds(30))
        emit("idleEnd", ["phase": phase, "start": start, "end": resources(), "duration": now - uptime])
    }
    private func cameraOffResourceWindow(_ phase: String) async throws {
        guard ProcessInfo.processInfo.environment["ROCK_CAMERA_PROFILE_WINDOWS"] == "1" else { return }
        let start = resources(), uptime = now
        emit("cameraOffResourceBegin", ["phase": phase])
        try await Task.sleep(for: .seconds(30))
        emit("cameraOffResourceEnd", ["phase": phase, "start": start, "end": resources(), "duration": now - uptime])
    }
    private func wait(seconds: Double = 20, _ predicate: () -> Bool) async throws {
        let deadline = now + seconds
        while !predicate(), now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard predicate() else { throw Failure("Readiness deadline exceeded") }
    }
    private func run() async throws {
        let headset = UserDefaults.standard.bool(forKey: "nativeDesktop.headsetMuteControls")
        emit("identity", ["pid": getpid(), "bundle": Bundle.main.bundleIdentifier ?? "", "headsetReady": headset,
            "audioProfile": GuestAudioProfile.saved.rawValue, "existingMicrophoneAuthorization": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized])
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw Failure("Existing microphone authorization required; no prompts") }
        guard !headset else { throw Failure("Unprimed benchmark requires the saved headset-ready option already disabled; preferences were preserved") }
        guard GuestAudioProfile.saved == .speech else { throw Failure("AEC benchmark requires the saved speech profile; preferences were preserved") }
        guard let channel = ProcessInfo.processInfo.environment["ROCK_STARTUP_CHANNEL"], UUID(uuidString: channel) != nil else { throw Failure("Unique ROCK_STARTUP_CHANNEL UUID required") }
        _ = LKRTCInitializeSSL()
        #if ROCK_COREAUDIO_DUPLEX_R6
        if noDemandSeamWarmup {
            try await qualifyNoDemandWaitSeams()
        }
        #endif
        try await idle("beforeMeeting")
        try await meeting()
        // The helper has returned, releasing its strong references before measuring idle.
        try await Task.sleep(for: .milliseconds(500))
        let released = releasedModel == nil && releasedAdapter == nil && releasedNative == nil && releasedPeer == nil
        acceptance = acceptance && released
        emit("meetingObjectsReleased", ["model": releasedModel == nil, "adapter": releasedAdapter == nil,
            "native": releasedNative == nil, "peer": releasedPeer == nil, "passed": released])
        try await idle("afterMeetingLeave")
    }
    #if ROCK_COREAUDIO_DUPLEX_R6
    private enum NoDemandSeam: String, CaseIterable { case firstActive, firstMuted, leave, persistentRestore }
    private func qualifyNoDemandWaitSeams() async throws {
        for scenario in NoDemandSeam.allCases {
            let owner = try await GuestSystemAudio.create(microphoneEnabled: false, playoutEnabled: false)
            var activation: Task<Bool, Never>?
            do {
                guard owner.backend == .coreAudioAEC3 else { throw Failure("No-demand seams require the opt-in R6 backend") }
                owner.setLocalMicrophoneIntentForDuplex(scenario != .firstActive && scenario != .leave)
                let restoring = scenario == .persistentRestore
                let task = Task { await owner.activateMicrophone(timeout: restoring ? 0.2 : 1, restoringPersistentInput: restoring) }
                activation = task
                try await wait(seconds: 1) { owner.duplexRecordingDemandWaitEvidenceForTesting["active"] as? Bool == true }
                let before = owner.duplexRecordingDemandWaitEvidenceForTesting
                guard let requestID = before["requestID"] as? String, UUID(uuidString: requestID) != nil,
                      let ownerID = (before["ownerGeneration"] as? NSNumber)?.uint64Value, ownerID > 0,
                      let started = before["startedUptime"] as? Double, started.isFinite,
                      let deadline = before["deadlineUptime"] as? Double, deadline.isFinite, deadline > started,
                      before["physicallyAdmitted"] as? Bool == false else { throw Failure("Waiting request identity or admission proof is invalid") }
                var queueResponsive: Bool?
                if scenario == .leave { owner.invalidateStoppedInputPreparation() }
                else {
                    owner.setLocalPlayoutIntent(true)
                    if restoring {
                        owner.setLocalMicrophoneIntentForDuplex(false)
                        owner.setLocalMicrophoneIntentForDuplex(true)
                        owner.setLocalMicrophoneIntentForDuplex(true)
                        owner.setLocalPlayoutIntent(false)
                    }
                    try await Task.sleep(for: .milliseconds(30))
                    guard owner.duplexRecordingDemandWaitEvidenceForTesting["active"] as? Bool == true else {
                        throw Failure("Mute/Sound change incorrectly withdrew the current wait")
                    }
                    if !restoring {
                        queueResponsive = await owner.endPrivateInputCheck(timeout: 0.2)
                        guard queueResponsive == true, owner.duplexRecordingDemandWaitEvidenceForTesting["active"] as? Bool == true else {
                            throw Failure("Audio queue was blocked by the recording-demand wait")
                        }
                        owner.setLocalMicrophoneIntentForDuplex(true)
                    }
                }
                let activated = await task.value
                activation = nil
                let result = owner.duplexRecordingDemandWaitEvidenceForTesting
                let expected = scenario == .leave ? "terminal" : restoring ? "timedOut" : "superseded"
                let state = owner.duplexStartupEvidenceForTesting
                let zeroHardware = ["physicalGeneration", "activePrepareSerial", "inputCreateCount", "inputStartCount", "outputCreateCount", "outputStartCount"].allSatisfy {
                    (state[$0] as? NSNumber)?.uint64Value == 0
                }
                let receipts = owner.snapshot["duplexPreparationReceipts"] as? [[String: Any]] ?? []
                let healthyWithdrawal = !owner.closeUnpreparedDuplexActivationAfterFailure()
                let finished = result["finishedUptime"] as? Double
                let authorizationClosed = (state["authority"] as? NSNumber).map { $0.uint64Value & 1 == 0 } == true &&
                    state["captureCommitted"] as? Bool == false
                guard !activated, result["status"] as? String == expected,
                      result["requestID"] as? String == requestID,
                      (result["ownerGeneration"] as? NSNumber)?.uint64Value == ownerID,
                      (state["ownerGeneration"] as? NSNumber)?.uint64Value == ownerID,
                      result["deadlineUptime"] as? Double == deadline,
                      result["startedUptime"] as? Double == started,
                      finished.map { $0.isFinite && $0 >= started } == true,
                      state["transportPinned"] as? Bool == false, zeroHardware, receipts.isEmpty,
                      authorizationClosed, healthyWithdrawal else {
                    throw Failure("No-demand cancellation/restore admitted hardware or lost its original request")
                }
                let stopped = await owner.shutdown()
                emit("noDemandProductionSeam", ["scenario": scenario.rawValue, "passed": stopped,
                    "wait": result, "before": before, "queueResponsive": queueResponsive as Any? ?? NSNull(),
                    "zeroPrepareAndHardware": zeroHardware && receipts.isEmpty, "physical": owner.snapshot,
                    "nativeAuthorizationClosed": authorizationClosed,
                    "coldStartupTimingQualified": false, "scope": "signed real factory; no peer/native recording demand"])
                guard stopped else { throw Failure("No-demand factory retirement failed") }
            } catch {
                owner.invalidateStoppedInputPreparation(); activation?.cancel(); _ = await activation?.value
                let stopped = await owner.shutdown()
                emit("noDemandProductionSeam", ["scenario": scenario.rawValue, "passed": false,
                    "cleanup": stopped, "error": String(describing: error), "physical": owner.snapshot])
                throw error
            }
        }
    }
    #endif
    private func startLogger() throws {
        guard let channel = ProcessInfo.processInfo.environment["ROCK_STARTUP_CHANNEL"].flatMap(UUID.init(uuidString:)),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw Failure("Missing diagnostic channel") }
        let directory = support.appendingPathComponent("StartupCapture").appendingPathComponent(channel.uuidString).appendingPathComponent("rtc-logs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let logger = LKRTCFileLogger(dirPath: directory.path, maxFileSize: 1_048_576)
        logger.severity = .info; logger.shouldDisableBuffering = false; logger.start()
        self.logger = logger; logDirectory = directory
        emit("rtcLogBegin", ["directory": directory.path, "maximumBytes": 1_048_576, "buffered": true])
    }
    private func stopLogger() {
        guard let logger else { return }; logger.stop()
        let path = logDirectory?.appendingPathComponent("rtc.log")
        let data = logger.logData(); var written = false
        if let path, let data { written = (try? data.write(to: path, options: .atomic)) != nil }
        if let data, data.count <= 1_048_576 { emit("rtcLogData", ["base64": data.base64EncodedString(), "bytes": data.count]) }
        self.logger = nil
        emit("rtcLogEnd", ["path": path?.path ?? "", "bytes": data?.count ?? 0, "written": written])
    }
    private func cachedPlayout(_ native: NativeGuestEngine) -> GuestAudioSnapshot {
        let value = native.systemAudio?.playoutMeterEvidence ?? [:]
        return .init(samples: value["samples"] as? Int ?? 0, energy: value["energy"] as? Double ?? 0,
            callbacks: value["callbacks"] as? Int ?? 0, nonSilentCallbacks: value["nonSilentCallbacks"] as? Int ?? 0,
            lastCallbackUptime: value["lastCallbackUptime"] as? Double, lastNonSilentUptime: value["lastNonSilentUptime"] as? Double)
    }
    private struct StartupBaseline {
        let actionID: String, cycle: Int
        let started: Double, publisherCompleted: Double, completed: Double
        let passive: [String: Any], publisher: [String: Any], receiver: [String: Any]
    }
    private final class StartupTimeline {
        let baseline: StartupBaseline, actionStart: Double
        var samples = 0
        var commandEnd: Double?
        var incompleteReason: String?
        var firstOutboundProgress: Double?, firstSourceEnergy: Double?, firstInboundProgress: Double?, firstPCM: Double?
        var firstPCMCallback: Double?
        var postActionInboundLower: Double?, postActionInboundUpper: Double?
        var previousInbound: (packets: Double, started: Double)?
        init(_ baseline: StartupBaseline, actionStart: Double) { self.baseline = baseline; self.actionStart = actionStart }
        var identity: [String: Any] { ["actionID": baseline.actionID, "cycle": baseline.cycle, "actionStart": actionStart] }
        func observe(publisher: [String: Any], receiver: [String: Any], publisherAt: Double) {
            func number(_ fields: [String: Any], _ key: String) -> Double { (fields[key] as? NSNumber)?.doubleValue ?? 0 }
            if publisher["statsAvailable"] as? Bool == true {
                if firstOutboundProgress == nil, number(publisher, "packets") > number(baseline.publisher, "packets") { firstOutboundProgress = publisherAt }
                if firstSourceEnergy == nil, number(publisher, "totalAudioEnergy") > number(baseline.publisher, "totalAudioEnergy") { firstSourceEnergy = publisherAt }
            }
            let inbound = receiver["subscriber"] as? [String: Any] ?? [:]
            let baselineInbound = baseline.receiver["subscriber"] as? [String: Any] ?? [:]
            let completed = receiver["sampleCompletedUptime"] as? Double ?? 0
            let started = receiver["sampleStartedUptime"] as? Double ?? 0
            if inbound["statsAvailable"] as? Bool == true, completed >= actionStart {
                let packets = number(inbound, "packets")
                if firstInboundProgress == nil, packets > number(baselineInbound, "packets") { firstInboundProgress = completed }
                if postActionInboundUpper == nil, let previousInbound, previousInbound.started >= actionStart,
                   packets > previousInbound.packets {
                    postActionInboundLower = previousInbound.started; postActionInboundUpper = completed
                }
                previousInbound = (packets, started)
            }
            let pcm = receiver["decodedPCM"] as? [String: Any] ?? [:]
            let baselinePCM = baseline.receiver["decodedPCM"] as? [String: Any] ?? [:]
            if firstPCM == nil, number(pcm, "energy") > number(baselinePCM, "energy"),
               number(pcm, "nonSilentCallbacks") > number(baselinePCM, "nonSilentCallbacks"),
               let callback = pcm["lastNonSilentUptime"] as? Double, callback >= actionStart {
                firstPCM = completed; firstPCMCallback = callback
            }
            samples += 1
        }
    }
    @MainActor private final class PrivateCheckHealth {
        var telemetryFresh = true, mutedThroughout = true, ownerMutedThroughout = true
        var maximumTelemetryAge = 0.0, samples = 0
        var firstSample: Double?, lastSample: Double?
        var maximumSampleGap = 0.0
        var maximumSampleGapStart: Double?, maximumSampleGapEnd: Double?
        var activeGraphSamples = 0, cleanupUnconfirmedObserved = false
        var activeTokens = Set<UInt64>(), maximumRevokedThroughToken: UInt64 = 0
        var requiredPrivateTokenSamples = 0, requiredPrivateTokenMaintained = true, requiredPrivateInputFresh = true
        var firstRequiredTokenFailure: [String: Any]?, firstRequiredInputFreshnessFailure: [String: Any]?
        var preReadClockWouldRejectSamples = 0
        var firstCallbackAdvanceDuringGetter: [String: Any]?
        private var previousRequiredMeter: [String: Any] = [:], previousRequiredGraph: [String: Any] = [:]
        private var previousRawBefore: Double?, previousRawAfter: Double?
        var lastGraph: [String: Any] = [:]
        func sample(peer: NativeStartupReceiverProxy, model: NativeDesktopMeetingModel, owner: GuestSystemAudio, at now: Double,
                    requiredPrivateToken: UInt64? = nil) {
            let received = peer.mediaSnapshot, age = now - peer.telemetryUptime
            maximumTelemetryAge = max(maximumTelemetryAge, age)
            telemetryFresh = telemetryFresh && received.connected && !received.failed && age >= 0 && age < 0.25
            mutedThroughout = mutedThroughout && !model.snapshot.microphoneOn && LKRTCApplicationCaptureMuted() == 1
            ownerMutedThroughout = ownerMutedThroughout && owner.snapshot["microphoneMuted"] as? Bool == true
            let graph = owner.privateInputGraphEvidenceForTesting
            if !graph.isEmpty {
                lastGraph = graph
                if graph["active"] as? Bool == true {
                    activeGraphSamples += 1
                    if let token = (graph["token"] as? NSNumber)?.uint64Value { activeTokens.insert(token) }
                }
                maximumRevokedThroughToken = max(maximumRevokedThroughToken,
                    (graph["revokedThroughToken"] as? NSNumber)?.uint64Value ?? 0)
                cleanupUnconfirmedObserved = cleanupUnconfirmedObserved || graph["cleanupUnconfirmed"] as? Bool == true
            }
            if let requiredPrivateToken {
                requiredPrivateTokenSamples += 1
                let tokenChecks: [String: Bool] = ["matchingToken": (graph["token"] as? NSNumber)?.uint64Value == requiredPrivateToken,
                    "requested": graph["requested"] as? Bool == true, "active": graph["active"] as? Bool == true,
                    "inputRunning": graph["inputRunning"] as? Bool == true, "notStarting": graph["startInFlight"] as? Bool == false,
                    "cleanupConfirmed": graph["cleanupUnconfirmed"] as? Bool == false]
                let tokenValid = tokenChecks.values.allSatisfy { $0 }
                func rawUptime() -> Double {
                    var clock = timespec(); clock_gettime(CLOCK_UPTIME_RAW, &clock)
                    return Double(clock.tv_sec) + Double(clock.tv_nsec) / 1e9
                }
                let rawBefore = rawUptime(), readBegan = ProcessInfo.processInfo.systemUptime
                let meter = owner.privateInputMeterEvidence, last = meter["lastCallbackUptime"] as? Double
                // A callback can advance while the getter reads its snapshot.
                // Compare with a clock sampled after that read, not before it.
                let rawAfter = rawUptime(), readEnded = ProcessInfo.processInfo.systemUptime
                if let last, last > rawBefore, last <= rawAfter {
                    preReadClockWouldRejectSamples += 1
                    if firstCallbackAdvanceDuringGetter == nil {
                        firstCallbackAdvanceDuringGetter = ["sampleUptime": now, "requiredToken": requiredPrivateToken,
                            "rawClockBeforeGetter": rawBefore, "rawClockAfterGetter": rawAfter, "callbackUptime": last,
                            "getterBeganUptime": readBegan, "getterEndedUptime": readEnded,
                            "meter": meter, "graphBeforeGetter": graph, "oldPreReadNonfutureCheckWouldReject": true]
                    }
                }
                let freshnessChecks: [String: Bool] = ["meterEnabled": meter["enabled"] as? Bool == true,
                    "callbackPresent": last != nil, "callbackNotFutureAtReadEnd": last.map { rawAfter >= $0 } == true,
                    "callbackYoungerThan250ms": last.map { rawAfter - $0 < 0.25 } == true]
                let fresh = freshnessChecks.values.allSatisfy { $0 }
                if (!tokenValid && firstRequiredTokenFailure == nil) || (!fresh && firstRequiredInputFreshnessFailure == nil) {
                    let failure: [String: Any] = ["sampleUptime": now, "requiredToken": requiredPrivateToken,
                        "tokenPredicates": tokenChecks, "freshnessPredicates": freshnessChecks,
                        "getterBeganUptime": readBegan, "getterEndedUptime": readEnded,
                        "rawClockBeforeGetter": rawBefore, "rawClockAfterGetter": rawAfter,
                        "callbackAgeAtReadEndSeconds": last.map { rawAfter - $0 } as Any? ?? NSNull(),
                        "callbackAdvancedPastPreReadClock": last.map { $0 > rawBefore } as Any? ?? NSNull(),
                        "previousRawClockBeforeGetter": previousRawBefore as Any? ?? NSNull(),
                        "previousRawClockAfterGetter": previousRawAfter as Any? ?? NSNull(),
                        "previousMeter": previousRequiredMeter, "previousGraph": previousRequiredGraph,
                        "meter": meter, "graphBeforeGetter": graph, "graphAfterGetter": owner.privateInputGraphEvidenceForTesting,
                        "globalCaptureMuted": LKRTCApplicationCaptureMuted() == 1,
                        "globalCaptureState": String(LKRTCApplicationCaptureState()), "modelSoundOn": model.snapshot.playoutOn,
                        "ownerCached": owner.snapshot]
                    if !tokenValid && firstRequiredTokenFailure == nil { firstRequiredTokenFailure = failure }
                    if !fresh && firstRequiredInputFreshnessFailure == nil { firstRequiredInputFreshnessFailure = failure }
                }
                requiredPrivateTokenMaintained = requiredPrivateTokenMaintained && tokenValid
                requiredPrivateInputFresh = requiredPrivateInputFresh && fresh
                previousRequiredMeter = meter; previousRequiredGraph = graph
                previousRawBefore = rawBefore; previousRawAfter = rawAfter
            }
            if firstSample == nil { firstSample = now }
            if let lastSample, now - lastSample > maximumSampleGap {
                maximumSampleGap = now - lastSample; maximumSampleGapStart = lastSample; maximumSampleGapEnd = now
            }
            lastSample = now; samples += 1
        }
        var probe: [String: Any] {
            ["samples": samples, "firstSampleUptime": firstSample as Any? ?? NSNull(),
             "lastSampleUptime": lastSample as Any? ?? NSNull(), "maximumTelemetryAgeSeconds": maximumTelemetryAge,
             "maximumSampleGapSeconds": maximumSampleGap,
             "maximumSampleGapStartUptime": maximumSampleGapStart as Any? ?? NSNull(),
             "maximumSampleGapEndUptime": maximumSampleGapEnd as Any? ?? NSNull(),
             "maximumAllowedSampleGapSeconds": 0.25,
             "receiverTelemetryFresh": telemetryFresh, "globalAndModelMutedThroughout": mutedThroughout,
             "ownerCachedMuteThroughout": ownerMutedThroughout, "activeGraphSamples": activeGraphSamples,
             "activeTokens": activeTokens.sorted(), "maximumRevokedThroughToken": maximumRevokedThroughToken,
             "cleanupUnconfirmedObserved": cleanupUnconfirmedObserved, "lastPrivateGraph": lastGraph,
             "requiredPrivateTokenSamples": requiredPrivateTokenSamples, "requiredPrivateTokenMaintained": requiredPrivateTokenMaintained,
             "requiredPrivateInputFresh": requiredPrivateInputFresh,
             "firstRequiredTokenFailure": firstRequiredTokenFailure as Any? ?? NSNull(),
             "firstRequiredInputFreshnessFailure": firstRequiredInputFreshnessFailure as Any? ?? NSNull(),
             "preReadClockWouldRejectSamples": preReadClockWouldRejectSamples,
             "firstCallbackAdvanceDuringGetter": firstCallbackAdvanceDuringGetter as Any? ?? NSNull(),
             "targetIntervalSeconds": 0.02, "ownerMuteIsCached": true]
        }
    }
    private func startupPassive(_ native: NativeGuestEngine, model: NativeDesktopMeetingModel) -> [String: Any] {
        let audio = native.systemAudio
        let cached = audio?.snapshot ?? [:]
        let keys = ["snapshotUptime", "microphoneMuted", "inputAvailable", "outputAvailable", "inputRunning", "outputRunning", "audioActiveOperation"]
        return ["sampleUptime": now, "rawInput": audio?.privateInputMeterEvidence ?? [:],
            "physicalPlayout": audio?.playoutMeterEvidence ?? [:],
            "ownerAtomic": audio?.microphoneStartupEvidenceForTesting ?? [:],
            "ownerCached": cached.filter { keys.contains($0.key) },
            "globalCaptureMuted": LKRTCApplicationCaptureMuted() == 1,
            "globalCaptureState": String(LKRTCApplicationCaptureState()),
            "modelMicrophoneOn": model.snapshot.microphoneOn, "modelMicrophoneStarting": model.microphoneStarting]
    }
    private func startupBaseline(cycle: Int, native: NativeGuestEngine, model: NativeDesktopMeetingModel,
                                 peer: NativeStartupReceiverProxy) async throws -> StartupBaseline {
        try Task.checkCancellation()
        let actionID = UUID().uuidString, started = now
        let passive = startupPassive(native, model: model)
        let rows = await native.screenShareStatsForTesting(.publisher)
        let publisherCompleted = now
        try Task.checkCancellation()
        let publisher = StartupAudioStageStatistics.summary(rows, publisher: true)
        let receiver = await peer.startupStageEvidence(actionID: actionID, cycle: cycle, actionStart: nil, phase: "baseline")
        try Task.checkCancellation()
        let completed = now, receiverSample = receiver["sampleCompletedUptime"] as? Double ?? 0
        let receiverStarted = receiver["sampleStartedUptime"] as? Double ?? 0
        let subscriber = receiver["subscriber"] as? [String: Any] ?? [:]
        let publisherTransportReady = StartupTransportReadiness.confirmed(publisher)
        let receiverTransportReady = StartupTransportReadiness.confirmed(subscriber)
        guard publisher["statsAvailable"] as? Bool == true,
              subscriber["statsAvailable"] as? Bool == true,
              publisherTransportReady, receiverTransportReady,
              StartupTransportReadiness.queryBracketsConfirmed(publisherStarted: started, publisherCompleted: publisherCompleted,
                  receiverStarted: receiverStarted, receiverCompleted: receiverSample, baselineCompleted: completed) else {
            emit("micStartupStageBaselineFailed", ["actionID": actionID, "cycle": cycle, "publisher": publisher, "receiver": receiver,
                "publisherTransportReady": publisherTransportReady, "receiverTransportReady": receiverTransportReady,
                "publisherSampleStartedUptime": started, "publisherSampleCompletedUptime": publisherCompleted,
                "receiverSampleStartedUptime": receiverStarted, "receiverSampleCompletedUptime": receiverSample,
                "baselineCompletedUptime": completed, "nativeStatsMayPrecedeRequest": true])
            throw Failure("Startup stage baseline was unavailable, its query brackets exceeded 250 ms, or its transport was not connected; microphone intent was not issued")
        }
        return StartupBaseline(actionID: actionID, cycle: cycle, started: started, publisherCompleted: publisherCompleted, completed: completed,
            passive: passive, publisher: publisher, receiver: receiver)
    }
    private func startStartupStages(_ baseline: StartupBaseline, actionStart: Double, native: NativeGuestEngine,
                                    model: NativeDesktopMeetingModel, peer: NativeStartupReceiverProxy) {
        let timeline = StartupTimeline(baseline, actionStart: actionStart)
        startupTimeline = timeline
        startupStageTask = Task { @MainActor [weak self, weak native, weak model, weak peer] in
            guard let self else { return }
            var initial = timeline.identity
            initial.merge(["phase": "baseline", "baselineStartedUptime": baseline.started,
                "baselineCompletedUptime": baseline.completed, "baselineAgeAtActionSeconds": actionStart - baseline.completed,
                "publisherBaselineAgeAtActionSeconds": actionStart - baseline.publisherCompleted,
                "passive": baseline.passive, "publisher": baseline.publisher, "receiver": baseline.receiver,
                "targetIntervalSeconds": 0.15, "instrumentedTiming": true,
                "baselineFreshness": "bounded-query-and-response-times", "nativeReportFreshnessProven": false]) { _, new in new }
            self.emit("micStartupStage", initial)
            while !Task.isCancelled, self.now - actionStart < 15, timeline.samples < 100 {
                guard let native, let model, let peer else { return }
                let started = self.now, passive = self.startupPassive(native, model: model)
                let rows = await native.screenShareStatsForTesting(.publisher)
                let publisherAt = self.now
                if rows == nil { timeline.incompleteReason = "publisherStatsUnavailableOrUnconfirmed" }
                guard !Task.isCancelled else { return }
                let publisher = StartupAudioStageStatistics.summary(rows, publisher: true)
                guard publisher["statsAvailable"] as? Bool == true else { timeline.incompleteReason = "publisherStatsUnavailable"; return }
                let receiver = await peer.startupStageEvidence(actionID: baseline.actionID, cycle: baseline.cycle,
                    actionStart: actionStart, phase: "timeline")
                if (receiver["subscriber"] as? [String: Any])?["statsAvailable"] as? Bool != true {
                    timeline.incompleteReason = "receiverStatsUnavailableOrUnconfirmed"
                }
                guard !Task.isCancelled else { return }
                timeline.observe(publisher: publisher, receiver: receiver, publisherAt: publisherAt)
                var fields = timeline.identity
                fields.merge(["phase": "timeline", "sample": timeline.samples, "sampleStartedUptime": started,
                    "publisherSampleCompletedUptime": publisherAt, "sampleCompletedUptime": self.now,
                    "commandEnd": timeline.commandEnd as Any? ?? NSNull(), "passive": passive,
                    "publisher": publisher, "receiver": receiver, "adapterStages": self.adapter?.microphoneStartupMilliseconds ?? [:],
                    "speechClassified": false]) { _, new in new }
                self.emit("micStartupStage", fields)
                guard (receiver["subscriber"] as? [String: Any])?["statsAvailable"] as? Bool == true else {
                    timeline.incompleteReason = "receiverStatsUnavailableOrUnconfirmed"; return
                }
                let delay = max(0, 0.15 - (self.now - started))
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }
    private func completeStartupCommand(_ commandEnd: Double, native: NativeGuestEngine, model: NativeDesktopMeetingModel) {
        guard let timeline = startupTimeline else { return }
        timeline.commandEnd = commandEnd
        var fields = timeline.identity
        fields.merge(["phase": "commandComplete", "commandEnd": commandEnd, "passive": startupPassive(native, model: model),
            "adapterStages": adapter?.microphoneStartupMilliseconds ?? [:]]) { _, new in new }
        emit("micStartupStage", fields)
    }
    private func finishStartupStages(remoteReady: Double?) async throws {
        guard let timeline = startupTimeline else { return }
        startupStageTask?.cancel(); await startupStageTask?.value; startupStageTask = nil; startupTimeline = nil
        var fields = timeline.identity
        fields.merge(["phase": "summary", "samples": timeline.samples, "commandEnd": timeline.commandEnd as Any? ?? NSNull(),
            "firstOutboundPacketProgressObservedUptime": timeline.firstOutboundProgress as Any? ?? NSNull(),
            "firstMediaSourceEnergyProgressObservedUptime": timeline.firstSourceEnergy as Any? ?? NSNull(),
            "firstInboundPacketProgressObservedUptime": timeline.firstInboundProgress as Any? ?? NSNull(),
            "postActionRequestProgressIntervalStartUptime": timeline.postActionInboundLower as Any? ?? NSNull(),
            "postActionRequestProgressIntervalEndUptime": timeline.postActionInboundUpper as Any? ?? NSNull(),
            "firstDecodedNonzeroObservedUptime": timeline.firstPCM as Any? ?? NSNull(),
            "lastNonzeroCallbackInFirstPositiveSnapshotUptime": timeline.firstPCMCallback as Any? ?? NSNull(),
            "remoteNonzeroPollingUpperUptime": remoteReady as Any? ?? NSNull(),
            "inboundProgressObservedByPollingPCM": timeline.firstInboundProgress.flatMap { packet in remoteReady.map { packet <= $0 } } as Any? ?? NSNull(),
            "packetTimesAreObservationBounds": true, "baselinePacketWindowIncludesPreActionTime": true,
            "requestIntervalIsPacketArrivalBound": false, "nativeStatsMayPrecedeRequest": true,
            "nonzeroPCMIsSpeechQualityProof": false, "speechClassified": false]) { _, new in new }
        fields["incompleteReason"] = timeline.incompleteReason as Any? ?? NSNull()
        emit("micStartupStage", fields)
        if timeline.incompleteReason != nil { throw Failure("Startup stage sampling lost stats confirmation; no further stats requests were issued") }
    }
    private func beginWindow(_ key: String, _ native: NativeGuestEngine) {
        windows[key] = ReceiveWindow(decoded: native.mediaSnapshot.audio, playout: cachedPlayout(native), at: now)
    }
    private func endWindow(_ key: String, _ native: NativeGuestEngine) -> [String: Any] {
        guard let window = windows.removeValue(forKey: key) else { acceptance = false; return ["passed": false] }
        window.sample(decoded: native.mediaSnapshot.audio, playout: cachedPlayout(native), at: now)
        let value = window.result(at: now); acceptance = acceptance && value["passed"] as? Bool == true
        return value
    }
    private func startMonitor(_ native: NativeGuestEngine) {
        let started = now
        monitor = Task { @MainActor [weak self, weak native] in
            var previous = started
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                guard let self, let native else { return }
                let time = self.now, interval = time - previous
                if interval > self.maximumMainInterval { self.maximumMainInterval = interval; self.mainGapStart = previous; self.mainGapEnd = time }
                for window in self.windows.values {
                    window.sample(decoded: native.mediaSnapshot.audio, playout: self.cachedPlayout(native), at: time)
                    window.sampleMain(from: previous, to: time)
                }
                previous = time
            }
        }
    }
    #if ROCK_COREAUDIO_DUPLEX_R6
    private func startRawStartSupersessionProbe() {
        guard rawStartSupersessionEnabled else { return }
        emit("controlledRawStartTrackSupersessionBegin", ["pollBudgetSeconds": 20, "pollIntervalMilliseconds": 2,
            "mutation": "one existing track invalidation; no SDK hold or transport change"])
        rawStartSupersessionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = self.now + 20
            while !Task.isCancelled, self.now < deadline {
                if let native = self.adapter?.currentNativeEngine, let audio = native.systemAudio,
                   let first = StartupRawOutputSupersession.window(duplex: audio.duplexStartupEvidenceForTesting,
                       operation: audio.snapshot["audioActiveOperation"] as? [String: Any] ?? [:], at: self.now),
                   LKRTCApplicationCaptureMuted() == 1 {
                    let current = StartupRawOutputSupersession.window(duplex: audio.duplexStartupEvidenceForTesting,
                        operation: audio.snapshot["audioActiveOperation"] as? [String: Any] ?? [:], at: self.now)
                    if let current, current.same(as: first), self.adapter?.currentNativeEngine === native,
                       native.systemAudio === audio, LKRTCApplicationCaptureMuted() == 1 {
                        // No await, stdout or native hardware query inside the
                        // observed marker-to-return window before the one latch.
                        let before = self.now
                        audio.invalidateDuplexPublicationForTrackChange()
                        let after = self.now
                        self.rawStartSupersessionAttempt = StartupRawOutputSupersession.attempt(window: current,
                            before: before, after: after, latches: audio.snapshot["duplexIntentLatches"] as? [[String: Any]] ?? [])
                        return
                    }
                }
                do { try await Task.sleep(for: .milliseconds(2)) } catch { return }
            }
        }
    }
    private func finishRawStartSupersessionProbe(_ native: NativeGuestEngine?) {
        guard rawStartSupersessionEnabled, !rawStartSupersessionReported else { return }
        rawStartSupersessionReported = true
        let audio = native?.systemAudio
        let result = StartupRawOutputSupersession.verify(rawStartSupersessionAttempt,
            duplex: audio?.duplexStartupEvidenceForTesting ?? [:],
            core: audio?.microphoneStartupEvidenceForTesting["coreAudio"] as? [String: Any] ?? [:], snapshot: audio?.snapshot ?? [:])
        let gatesClosed = LKRTCApplicationCaptureMuted() == 1 && model?.snapshot.microphoneOn != true
        let passed = result.exercised && gatesClosed
        acceptance = acceptance && passed
        emit("controlledRawStartTrackSupersession", ["attempted": rawStartSupersessionAttempt != nil,
            "exercised": passed, "passed": passed, "reason": result.reason, "captureGatesClosed": gatesClosed,
            "evidence": result.evidence, "clock": "ProcessInfo.systemUptime / native CLOCK_UPTIME_RAW nanoseconds",
            "scope": "phase13 marker-to-return control window; not Apple HAL internal execution or cold-latency proof"])
    }
    #endif
    private func meeting() async throws {
        let peer = try NativeStartupReceiverProxy(); self.peer = peer; releasedPeer = peer
        emit("networkBegin") // Launcher starts the separate synthetic receiver only after this flushed event.
        let invitation = try await peer.waitUntilReady(timeout: 30)
        emit("independentReceiverReady", peer.ipcEvidence)
        let policy = GuestICEPolicy(rawValue: ProcessInfo.processInfo.environment["ROCK_MIC_TEST_ICE_POLICY"] ?? "auto")
        guard let policy else { throw Failure("Invalid diagnostic ICE policy") }
        let adapter = NativeDesktopGuestEngine(icePolicy: policy); self.adapter = adapter; releasedAdapter = adapter
        let model = NativeDesktopMeetingModel(destination: try .verified(invitation, engine: .guest),
            name: "Physical microphone activation validation", title: "Disposable microphone activation", engine: adapter)
        self.model = model; releasedModel = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        self.window = window; window.contentView = NSHostingView(rootView: NativeDesktopMeetingView(model: model, onMini: {}))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try startLogger(); emit("joinBegin")
        if ProcessInfo.processInfo.environment["ROCK_MIC_FAULT_CASE"] == "leave-during-warmup" {
            try await leaveDuringWarmup(model, adapter: adapter)
            return
        }
        if ProcessInfo.processInfo.environment["ROCK_MIC_FAULT_CASE"] == "sound-off-during-warmup" {
            try await soundOffDuringWarmup(model, adapter: adapter)
            return
        }
        #if ROCK_COREAUDIO_DUPLEX_R6
        startRawStartSupersessionProbe()
        #endif
        try await model.connect()
        guard let native = adapter.currentNativeEngine else { throw Failure("No physical meeting engine") }
        releasedNative = native
        if ProcessInfo.processInfo.environment["ROCK_MIC_FAULT_CASE"] == "configuration-change-during-warmup" {
            let audio = native.systemAudio?.snapshot ?? [:]
            let skipped = audio["stoppedInputPreparationResult"] as? Int == 1
            let injected = audio["stoppedInputConfigurationChangeInjected"] as? Bool == true &&
                audio["stoppedInputConfigurationChangeDisableResult"] as? Int == 0 &&
                audio["stoppedInputConfigurationChangeRestoreResult"] as? Int == 0 &&
                audio["stoppedInputConfigurationChangeRestored"] as? Bool == true
            let discarded = (audio["preparedMeterGraphsDiscarded"] as? Int ?? 0) >= 1
            let captureClosed = !model.snapshot.microphoneOn && !model.microphoneStarting && !model.snapshot.cameraOn &&
                LKRTCApplicationCaptureMuted() == 1 && audio["inputAvailable"] as? Bool == false &&
                audio["microphoneMuted"] as? Bool == true
            emit("simulatedProfileFallbackPrepared", ["warmSkipped": skipped, "injectionAndRestorationSucceeded": injected,
                "stagedMeterGraphDiscarded": discarded, "captureClosed": captureClosed, "physical": audio,
                "simulation": "profile-ABA", "realRouteChangeValidated": false])
            guard skipped, injected, discarded, captureClosed else { throw Failure("Simulated profile change did not produce a safe skipped warm graph") }
        }
        do {
            try await wait {
                let decoded = native.mediaSnapshot.audio, playout = self.cachedPlayout(native)
                return decoded.energy > 0 && playout.energy > 0 &&
                    decoded.lastNonSilentUptime.map { self.now - $0 < 0.2 } == true && playout.lastNonSilentUptime.map { self.now - $0 < 0.2 } == true
            }
        } catch {
            let media = native.mediaSnapshot, playout = cachedPlayout(native)
            var liveAudio = native.systemAudio?.microphoneStartupEvidenceForTesting ?? [:]
            #if ROCK_COREAUDIO_DUPLEX_R6
            liveAudio["duplex"] = native.systemAudio?.duplexStartupEvidenceForTesting ?? [:]
            #endif
            emit("incomingReadinessFailure", ["receiver": peer.ipcEvidence, "connected": media.connected,
                "failed": media.failed, "decodedCallbacks": media.audio.callbacks, "decodedEnergy": media.audio.energy,
                "outputCallbacks": playout.callbacks, "outputEnergy": playout.energy,
                "physical": native.systemAudio?.snapshot ?? [:], "liveAudio": liveAudio])
            throw error
        }
        try await Task.sleep(for: .seconds(2))
        guard !model.snapshot.microphoneOn, !model.snapshot.cameraOn else { throw Failure("Capture unexpectedly active before first microphone intent") }
        try await wait { (native.mediaSnapshot.render["advancingFrames"] as? Int ?? 0) >= 10 &&
            (native.mediaSnapshot.render["lastFrameUptime"] as? Double).map { self.now - $0 < 0.2 } == true }
        emit("incomingReady", ["physicalAudio": native.systemAudio?.snapshot ?? [:]])
        #if ROCK_COREAUDIO_DUPLEX_R6
        if rawStartSupersessionEnabled {
            rawStartSupersessionTask?.cancel(); await rawStartSupersessionTask?.value; rawStartSupersessionTask = nil
            finishRawStartSupersessionProbe(native)
        }
        #endif
        if ProcessInfo.processInfo.environment["ROCK_MIC_FAULT_CASE"] == "leave-during-private-start" {
            startMonitor(native)
            try await leaveDuringPrivateStart(model, adapter: adapter, native: native, peer: peer)
            return
        }
        emit("diagnosticsBeforeActions", ["physical": await native.evidence()])
        startMonitor(native); try await Task.sleep(for: .milliseconds(200))
        if ProcessInfo.processInfo.environment["ROCK_MIC_PRIVATE_SOUND_OFF_ADMISSION"] == "1" {
            try await qualifySoundOffPrivateAdmission(adapter, model: model, native: native, peer: peer)
        }
        if ProcessInfo.processInfo.environment["ROCK_MIC_EXPECT_PRIVATE_REJECTION"] == "1" {
            try await qualifyPreOptInPrivateRejection(adapter, model: model, native: native, peer: peer)
        }
        if ProcessInfo.processInfo.environment["ROCK_MIC_PRIVATE_BEFORE_FIRST"] == "1" {
            let rawCount = ProcessInfo.processInfo.environment["ROCK_MIC_PRIVATE_BEFORE_FIRST_COUNT"] ?? "1"
            guard let count = Int(rawCount), (1...3).contains(count) else { throw Failure("Private check count must be between 1 and 3") }
            for cycle in 0..<count {
                try await qualifyPrivateCheck(adapter, model: model, native: native, peer: peer, phase: "before-first-\(cycle)")
            }
        }
        if ProcessInfo.processInfo.environment["ROCK_MIC_COMPARE_CAMERA"] == "1" {
            try await cameraOffResourceWindow("beforeFirstCamera")
            // Bounded DEBUG-only timing against the independent SFU receiver.
            var expectedCameraProfile: [Int]?, expectedCameraEffects: [Bool?]?
            for cycle in 0..<3 {
                let remoteBaseline = peer.mediaSnapshot.render["advancingFrames"] as? Int ?? 0
                let actionStart = now
                emit("cameraActionBegin", ["cycle": cycle, "actionStart": actionStart,
                    "epoch": Date().timeIntervalSince1970])
                model.toggleCamera(); await model.waitForMediaActionsForTesting()
                let commandEnd = now
                guard model.snapshot.cameraOn else { throw Failure(model.error ?? "Camera did not enable") }
                try await wait {
                    let remote = peer.mediaSnapshot.render
                    return (remote["advancingFrames"] as? Int ?? 0) >= remoteBaseline + 5 &&
                        (remote["lastFrameUptime"] as? Double).map { $0 >= actionStart && self.now - $0 < 0.25 } == true
                }
                let remoteReadyAt = now
                let cadenceHoldBegan = now
                let cadenceBefore = native.cameraSnapshot
                let cadenceRemoteBefore = peer.mediaSnapshot.render["advancingFrames"] as? Int ?? 0
                var cadenceHoldSeconds = 0.0
                if let raw = ProcessInfo.processInfo.environment["ROCK_CAMERA_CADENCE_HOLD_SECONDS"] {
                    guard let seconds = Double(raw), seconds >= 0, seconds <= 5 else { throw Failure("Invalid camera cadence hold duration") }
                    cadenceHoldSeconds = seconds
                    try await Task.sleep(for: .seconds(seconds))
                }
                guard let camera = native.cameraSnapshot, !camera.sampleProfileMismatch else {
                    throw Failure("Camera did not preserve its accepted sample profile")
                }
                var cadenceWindow: [String: Any] = [:]
                if cadenceHoldSeconds > 0 {
                    let remote = peer.mediaSnapshot
                    let remoteFrames = (remote.render["advancingFrames"] as? Int ?? 0) - cadenceRemoteBefore
                    let remoteAge = (remote.render["lastFrameUptime"] as? Double).map { now - $0 }
                    let telemetryAge = now - peer.telemetryUptime
                    guard let before = cadenceBefore, let first = before.lastPTSSeconds, let last = camera.lastPTSSeconds,
                          last > first, camera.advancingPTS > before.advancingPTS, remoteFrames > 0,
                          remote.connected, !remote.failed, telemetryAge >= 0, telemetryAge < 0.25,
                          remoteAge.map({ $0 >= 0 && $0 < 0.25 }) == true else {
                        throw Failure("Camera cadence window stopped delivering fresh local/remote frames")
                    }
                    cadenceWindow = ["requestedHoldSeconds": cadenceHoldSeconds, "observedWallSeconds": now - cadenceHoldBegan, "localAdvancingFrames": camera.advancingPTS - before.advancingPTS,
                        "ptsSeconds": last - first, "meanFPS": Double(camera.advancingPTS - before.advancingPTS) / (last - first),
                        "remoteAdvancingFrames": remoteFrames, "remoteEndAgeSeconds": remoteAge as Any? ?? NSNull(),
                        "receiverTelemetryAgeSeconds": telemetryAge]
                }
                let profile = [camera.width, camera.height, Int(camera.pixelFormat ?? 0)]
                guard let selected = camera.systemBackgroundSelected, let active = camera.systemBackgroundActive else {
                    throw Failure("Camera comparison effect state is unknown")
                }
                let effects: [Bool?] = [selected, active]
                if let expectedCameraProfile, let expectedCameraEffects {
                    guard profile == expectedCameraProfile, effects == expectedCameraEffects else {
                        throw Failure("Camera comparison changed actual resolution/pixel format/effect state")
                    }
                } else { expectedCameraProfile = profile; expectedCameraEffects = effects }
                if ProcessInfo.processInfo.environment["NATIVE_GUEST_CAMERA_SESSION_REUSE"] == "1", cycle > 0,
                   camera.startupMilliseconds["sessionGraphReused"] == nil {
                    throw Failure("Warm camera did not exercise the stopped graph reuse path")
                }
                emit("cameraActionEnd", ["cycle": cycle, "actionStart": actionStart,
                    "commandSeconds": commandEnd - actionStart, "remoteFreshFrameUpperSeconds": remoteReadyAt - actionStart,
                    "cameraStages": camera.startupMilliseconds, "cadenceWindow": cadenceWindow, "width": camera.width,
                    "height": camera.height, "frames": camera.frames,
                    "pixelFormat": camera.pixelFormat ?? 0,
                    "systemBackgroundSelected": camera.systemBackgroundSelected as Any? ?? NSNull(),
                    "systemBackgroundActive": camera.systemBackgroundActive as Any? ?? NSNull(),
                    "measuredFPS": camera.measuredFPS as Any? ?? NSNull(),
                    "ptsSpanSeconds": camera.ptsSpanSeconds as Any? ?? NSNull(),
                    "maximumPTSGapSeconds": camera.maximumPTSGapSeconds as Any? ?? NSNull(),
                    "dropped": camera.dropped as Any? ?? NSNull(),
                    "remoteBaseline": remoteBaseline,
                    "remote": peer.mediaSnapshot.render, "incoming": native.mediaSnapshot.render,
                    "mainActorMaximumSeconds": maximumMainInterval])
                model.toggleCamera(); await model.waitForMediaActionsForTesting()
                guard !model.snapshot.cameraOn else { throw Failure("Camera did not stop") }
                try await Task.sleep(for: .seconds(2))
                emit("cameraOff", ["cycle": cycle, "epoch": Date().timeIntervalSince1970,
                    "cameraAbsent": native.cameraSnapshot == nil,
                    "cache": native.cameraSessionReuseSnapshotForTesting as Any? ?? NSNull()])
            }
            try await cameraOffResourceWindow("afterCameraStopped")
            guard await cleanup() else { throw Failure("Camera comparison cleanup failed") }
            let cache = native.cameraSessionReuseSnapshotForTesting
            if ProcessInfo.processInfo.environment["NATIVE_GUEST_CAMERA_SESSION_REUSE"] == "1" {
                guard cache?["closed"] as? Bool == true, cache?["borrowedCount"] as? Int == 0,
                      cache?["parkedCount"] as? Int == 0, cache?["stopFailed"] as? Bool == false else {
                    throw Failure("Stopped camera graph ownership did not fully release")
                }
            }
            emit("cameraCleanup", ["cache": cache as Any? ?? NSNull(),
                                   "mainActorMaximumSeconds": maximumMainInterval])
            guard maximumMainInterval < 0.35 else { throw Failure("Camera activation blocked the UI monitor") }
            return
        }
        if let scenario = ProcessInfo.processInfo.environment["ROCK_MIC_FAULT_CASE"] {
            if scenario == "leave-unused-cache" {
                let before = native.systemAudio?.snapshot ?? [:]
                guard before["stoppedInputPreparationResult"] as? Int == 0 else { throw Failure("Stopped cache was not prepared") }
                let clean = await cleanup()
                let after = native.systemAudio?.snapshot ?? [:]
                emit("unusedCacheLeave", ["prepared": before["stoppedInputPreparationResult"] as Any? ?? NSNull(),
                    "cleanup": clean, "physical": after, "microphoneWasNeverEnabled": !model.snapshot.microphoneOn])
                guard clean, after["cleanupSucceeded"] as? Bool == true,
                      (after["meterGraphOwners"] as? Int ?? -1) == 0 else { throw Failure("Unused cache cleanup failed") }
                return
            }
            if scenario == "discard-cache-before-mic" || scenario == "configuration-change-during-warmup" {
                let simulatedProfileChange = scenario == "configuration-change-during-warmup"
                if !simulatedProfileChange {
                    guard native.systemAudio?.snapshot["stoppedInputPreparationResult"] as? Int == 0,
                          await native.systemAudio?.discardStoppedInputGraphForTesting() == true else {
                        throw Failure("Could not discard ready cache before fallback")
                    }
                }
                native.systemAudio?.setPrivateInputMeterEnabled(true)
                let before = peer.mediaSnapshot.audio, began = now
                model.toggleMicrophone(); await model.waitForMediaActionsForTesting()
                guard model.snapshot.microphoneOn else { throw Failure("Cache-miss microphone did not enable") }
                try await wait {
                    let received = peer.mediaSnapshot.audio
                    return received.callbacks > before.callbacks && received.energy > before.energy &&
                        received.lastNonSilentUptime.map { $0 >= began && self.now - $0 < 0.2 } == true
                }
                let physical = await native.evidence(), audio = native.systemAudio?.snapshot ?? [:]
                let normal = audio["echoCancellationActive"] as? Bool == true &&
                    audio["voiceProcessingBypassedActive"] as? Bool == false &&
                    (audio["inputSampleRate"] as? Double ?? 0) == 48000 &&
                    (!simulatedProfileChange || (audio["voiceProcessingActive"] as? Bool == true &&
                        [44100.0, 48000.0].contains(audio["outputSampleRate"] as? Double ?? 0)))
                emit(simulatedProfileChange ? "simulatedProfileFallback" : "cacheMissFallback",
                    ["normalProcessing": normal, "remotePCM": true, "seconds": now - began, "physical": physical,
                     "simulatedProfileChange": simulatedProfileChange, "realRouteChangeValidated": false])
                model.toggleMicrophone(); await model.waitForMediaActionsForTesting()
                let muted = !model.snapshot.microphoneOn && LKRTCApplicationCaptureMuted() == 1
                guard await cleanup(), normal, muted else { throw Failure("Cache-miss processing/mute/cleanup failed") }
                return
            }
            try await staleIntentScenario(scenario, model: model, native: native, peer: peer)
            return
        }
        if let raw = ProcessInfo.processInfo.environment["ROCK_MIC_CONNECTED_HOLD_SECONDS"] {
            guard let seconds = Double(raw), seconds >= 0, seconds <= 60 else { throw Failure("Invalid connected hold duration") }
            if ProcessInfo.processInfo.environment["ROCK_MAC_MIC_PREFLIGHT"] == "bridge-cache" {
                guard native.systemAudio?.snapshot["stoppedInputPreparationResult"] as? Int == 0 else { throw Failure("Stopped cache was not prepared") }
            }
            let remote = await peer.evidence()
            guard remote["subscriberConnected"] as? Bool == true else { throw Failure("Independent receiver transport is not ready for retained-call profiling") }
            emit("connectedHoldBegin", ["seconds": seconds, "physical": native.systemAudio?.snapshot ?? [:]])
            try await Task.sleep(for: .seconds(seconds))
            emit("connectedHoldEnd", ["physical": native.systemAudio?.snapshot ?? [:]])
        }
        let processingBefore = native.systemAudio?.snapshot["experimentalProcessing"] as? [String: Any] ?? [:]
        beginWindow("actions", native)
        for cycle in 0..<3 {
            let stagedBaseline: StartupBaseline?
            if startupStagesEnabled { stagedBaseline = try await startupBaseline(cycle: cycle, native: native, model: model, peer: peer) }
            else { stagedBaseline = nil }
            // Capture both receive baselines BEFORE the enable; activation itself is inside the measured window.
            beginWindow("enable", native)
            native.systemAudio?.setPrivateInputMeterEnabled(true)
            let remoteBaseline = peer.mediaSnapshot.audio, actionStart = now, mainBefore = maximumMainInterval
            emit("micActionBegin", ["cycle": cycle, "enabled": true, "actionStart": actionStart])
            model.toggleMicrophone()
            if let stagedBaseline { startStartupStages(stagedBaseline, actionStart: actionStart, native: native, model: model, peer: peer) }
            await model.waitForMediaActionsForTesting()
            let commandEnd = now
            if startupStagesEnabled { completeStartupCommand(commandEnd, native: native, model: model) }
            guard model.snapshot.microphoneOn else { throw Failure(model.error ?? "Microphone did not enable") }
            var inputReady: Double?, remoteReady: Double?
            let holdEnd = now + 5
            while now < holdEnd {
                let input = native.systemAudio?.privateInputMeterEvidence ?? [:], remote = peer.mediaSnapshot.audio.since(remoteBaseline)
                if inputReady == nil, (input["callbacks"] as? Int ?? 0) > 0,
                   (input["lastCallbackUptime"] as? Double ?? 0) >= actionStart { inputReady = now }
                if remoteReady == nil, remote.nonSilentCallbacks > 0, remote.energy > 0,
                   remote.lastNonSilentUptime.map({ $0 >= actionStart }) == true { remoteReady = now }
                try await Task.sleep(for: .milliseconds(20))
            }
            let qualified = inputReady != nil && remoteReady != nil
            acceptance = acceptance && qualified
            let videoWindow = native.subscriber?.renderer.window(from: actionStart, to: now) ?? .invalid
            let videoPassed = videoWindow.complete && videoWindow.frames > 0 && videoWindow.maximumGap < 0.35 &&
                videoWindow.endFrameAge.map { $0 < 0.2 } == true
            acceptance = acceptance && videoPassed
            emit("micActionEnd", ["video": videoWindow.evidence, "videoPassed": videoPassed,
                "cycle": cycle, "enabled": true, "actionStart": actionStart, "commandEnd": commandEnd,
                "commandSeconds": commandEnd - actionStart, "inputFreshUpperSeconds": inputReady.map { $0 - actionStart } as Any? ?? NSNull(),
                "remoteNonzeroUpperSeconds": remoteReady.map { $0 - actionStart } as Any? ?? NSNull(), "freshPCMObserved": qualified,
                "speechClassified": false, "input": native.systemAudio?.privateInputMeterEvidence ?? [:],
                "stages": adapter.microphoneStartupMilliseconds, "incoming": endWindow("enable", native),
                "mainActorMaximumSeconds": maximumMainInterval, "mainActorMaximumBefore": mainBefore])
            if startupStagesEnabled { try await finishStartupStages(remoteReady: remoteReady) }
            if cycle == 0, ProcessInfo.processInfo.environment["ROCK_MIC_CAMERA_INTERACTION"] == "1" {
                for cameraCycle in 0..<2 {
                    let baseline = peer.mediaSnapshot.render["advancingFrames"] as? Int ?? 0, began = now
                    model.toggleCamera(); await model.waitForMediaActionsForTesting()
                    guard model.snapshot.cameraOn, model.snapshot.microphoneOn else { throw Failure("Duplex camera did not enable") }
                    try await wait { (peer.mediaSnapshot.render["advancingFrames"] as? Int ?? 0) >= baseline + 5 &&
                        (peer.mediaSnapshot.render["lastFrameUptime"] as? Double).map { $0 >= began && self.now - $0 < 0.25 } == true }
                    let stages = native.cameraSnapshot?.startupMilliseconds ?? [:]
                    if cameraCycle > 0, ProcessInfo.processInfo.environment["NATIVE_GUEST_CAMERA_SESSION_REUSE"] == "1",
                       stages["sessionGraphReused"] == nil { throw Failure("Combined test did not reuse stopped camera graph") }
                    emit("cameraWhileMicrophoneOn", ["cycle": cameraCycle, "cameraStages": stages,
                        "measuredFPS": native.cameraSnapshot?.measuredFPS as Any? ?? NSNull(),
                        "microphoneOn": model.snapshot.microphoneOn, "remoteFrames": peer.mediaSnapshot.render])
                    if cameraCycle == 0 { model.toggleCamera(); await model.waitForMediaActionsForTesting(); try await Task.sleep(for: .seconds(1)) }
                }
            }
            beginWindow("mute", native); let muteStart = now
            emit("micActionBegin", ["cycle": cycle, "enabled": false, "actionStart": muteStart])
            model.toggleMicrophone(); await model.waitForMediaActionsForTesting()
            guard !model.snapshot.microphoneOn else { throw Failure("Microphone did not mute") }
            try await Task.sleep(for: .seconds(1))
            emit("micActionEnd", ["cycle": cycle, "enabled": false, "actionStart": muteStart, "incoming": endWindow("mute", native)])
        }
        let continuity = endWindow("actions", native)
        if let raw = ProcessInfo.processInfo.environment["ROCK_MIC_POST_ACTION_HOLD_SECONDS"] {
            guard let seconds = Double(raw), seconds >= 0, seconds <= 30 else { throw Failure("Invalid post-action hold duration") }
            emit("postActionHoldBegin", ["seconds": seconds, "physical": native.systemAudio?.snapshot ?? [:]])
            try await Task.sleep(for: .seconds(seconds))
            emit("postActionHoldEnd", ["physical": native.systemAudio?.snapshot ?? [:]])
        }
        if ProcessInfo.processInfo.environment["ROCK_MIC_EXTRA_LIFECYCLE"] == "1" {
            model.togglePlayout(); await model.waitForMediaActionsForTesting()
            guard !model.snapshot.playoutOn else { throw Failure("Sound did not turn off") }
            try await Task.sleep(for: .milliseconds(300))
            let offBaseline = cachedPlayout(native)
            try await Task.sleep(for: .seconds(1))
            let off = cachedPlayout(native).since(offBaseline)
            emit("soundOffWindow", ["energy": off.energy, "callbacks": off.callbacks,
                "outputAvailable": native.systemAudio?.snapshot["outputAvailable"] as Any? ?? NSNull()])
            guard off.energy <= 1e-9, native.systemAudio?.snapshot["outputAvailable"] as? Bool == false else {
                throw Failure("Meeting audio continued during Sound off")
            }
            let restoreAt = now
            model.togglePlayout(); await model.waitForMediaActionsForTesting()
            try await wait { model.snapshot.playoutOn && self.cachedPlayout(native).lastNonSilentUptime.map { $0 >= restoreAt && self.now - $0 < 0.2 } == true }
            let restoreSeconds = now - restoreAt
            beginWindow("privateCheck", native)
            try await qualifyPrivateCheck(adapter, model: model, native: native, peer: peer, phase: "afterMicrophoneMuted")
            try await Task.sleep(for: .seconds(1))
            let privateContinuity = endWindow("privateCheck", native)
            emit("extraLifecycle", ["soundRestoredSeconds": restoreSeconds, "privateCheck": privateContinuity,
                                    "meetingMicrophoneMuted": !model.snapshot.microphoneOn])
        }
        monitor?.cancel(); await monitor?.value; monitor = nil
        acceptance = acceptance && maximumMainInterval < 0.35
        emit("incomingAcrossActions", ["incoming": continuity, "mainActorMaximumSeconds": maximumMainInterval,
            "mainActorGapStart": mainGapStart, "mainActorGapEnd": mainGapEnd])
        // Stats and ADM refreshes run only after all critical timing windows have ended.
        let evidence = await native.evidence()
        if native.systemAudio?.backend.usesAudioEngine == false {
            let audio = native.systemAudio?.snapshot ?? [:]
            let state = audio["coreAudio"] as? [String: Any] ?? [:]
            let processing = audio["experimentalProcessing"] as? [String: Any] ?? [:]
            let physical = native.systemAudio?.playoutMeterEvidence ?? [:]
            let qualified = state["supported"] as? Bool == true && state["enabled"] as? Bool == true &&
                state["cleanupUnconfirmed"] as? Bool == false &&
                audio["softwareEchoCancellationActive"] as? Bool == true &&
                audio["echoCancellationSoftwareResolved"] as? Bool == true &&
                audio["platformEchoCancellationActive"] as? Bool == false &&
                audio["voiceProcessingActive"] as? Bool == false &&
                audio["softwareNoiseSuppressionActive"] as? Bool == true &&
                audio["softwareAutoGainControlActive"] as? Bool == true &&
                processing["diagnosticsEnabled"] as? Bool == true && processing["aec3Active"] as? Bool == true &&
                (processing["aec3ConstructionCount"] as? Int ?? 0) > 0 &&
                (processing["aec3CaptureCalls"] as? Int ?? 0) > (processingBefore["aec3CaptureCalls"] as? Int ?? 0) &&
                (processing["aec3RenderCalls"] as? Int ?? 0) > (processingBefore["aec3RenderCalls"] as? Int ?? 0) &&
                physical["energyKnown"] as? Bool == true &&
                (physical["lastNonSilentUptime"] as? Double).map { self.now - $0 >= 0 && self.now - $0 < 0.2 } == true
            emit("coreAudioProcessingQualification", ["passed": qualified, "physical": audio,
                "processingBefore": processingBefore, "outputIOProc": physical,
                "acousticDoubleTalkQualified": false])
            guard qualified else { throw Failure("CoreAudio/AEC3 implementation and physical-output proof failed") }
        }
        emit("diagnostics", ["physical": evidence, "remote": await peer.evidence(), "acceptance": acceptance])
        #if ROCK_COREAUDIO_DUPLEX_R6
        if ProcessInfo.processInfo.environment["ROCK_MIC_LEAVE_DURING_BORROW"] == "1" {
            let preview = NativeDesktopDeviceModel(discoverCameras: { [] })
            preview.startAudioCheck(live: true,
                start: { try await adapter.startPrivateAudioCheck() },
                stop: { try await adapter.stopPrivateAudioCheck() },
                level: { adapter.privateAudioLevel })
            try await wait(seconds: 5) { preview.error == nil && adapter.privateAudioLevel != nil }
            guard preview.checkingAudio, !model.snapshot.microphoneOn else { throw Failure("Borrowed preview did not become active privately") }
            let left = await model.leave()
            let previewStopped = !preview.checkingAudio && preview.error == nil
            emit("leaveDuringBorrowedPreview", ["left": left, "previewStopped": previewStopped,
                "phase": String(describing: model.snapshot.phase), "physical": native.systemAudio?.snapshot ?? [:]])
            guard left, previewStopped else { throw Failure("Leave did not cleanly stop the active borrowed preview") }
        }
        #endif
        guard await cleanup() else { throw Failure("Meeting cleanup was not confirmed") }
    }

    private func privateSoundCaptureClosed(_ model: NativeDesktopMeetingModel, native: NativeGuestEngine,
                                           owner: GuestSystemAudio, allowPrivateInput: Bool = false) -> Bool {
        let senders = native.audioSenderTrackEnabledForTesting
        return !model.snapshot.microphoneOn && !model.microphoneStarting && LKRTCApplicationCaptureMuted() == 1 &&
            owner.snapshot["microphoneMuted"] as? Bool == true && (allowPrivateInput || owner.snapshot["inputAvailable"] as? Bool == false) &&
            !senders.isEmpty && senders.allSatisfy { !$0 }
    }
    private func privateSoundGraphValid(_ owner: GuestSystemAudio, token: UInt64?) -> Bool {
        let graph = owner.privateInputGraphEvidenceForTesting
        guard graph["supported"] as? Bool == true, graph["cleanupUnconfirmed"] as? Bool == false else { return false }
        if let token {
            return (graph["token"] as? NSNumber)?.uint64Value == token && graph["active"] as? Bool == true &&
                graph["requested"] as? Bool == true && graph["inputRunning"] as? Bool == true &&
                graph["startInFlight"] as? Bool == false && graph["outputMode"] as? String == "none" &&
                graph["privateOutputInstantiated"] as? Bool == false && graph["publishingAllowed"] as? Bool == false &&
                (graph["silentOutputCallbacks"] as? NSNumber)?.intValue == 0
        }
        return graph["confirmedStopped"] as? Bool == true && graph["active"] as? Bool == false &&
            graph["requested"] as? Bool == false && graph["startInFlight"] as? Bool == false && graph["inputRunning"] as? Bool == false
    }
    private func privateSoundQuietWindow(_ model: NativeDesktopMeetingModel, native: NativeGuestEngine,
                                         owner: GuestSystemAudio, token: UInt64?, phase: String, step: String,
                                         readbackAfter: Double, baseline: GuestAudioSnapshot? = nil) async throws -> [String: Any] {
        let began = now, before = baseline ?? cachedPlayout(native)
        var intentStayedOff = true, privateStateRetained = true, senderStayedMuted = true
        let end = now + 0.5
        while now < end {
            let audio = owner.snapshot
            intentStayedOff = intentStayedOff && !model.snapshot.playoutOn && audio["playoutEnabledRequested"] as? Bool == false &&
                audio["outputAvailable"] as? Bool == false
            privateStateRetained = privateStateRetained && privateSoundGraphValid(owner, token: token)
            senderStayedMuted = senderStayedMuted && privateSoundCaptureClosed(model, native: native, owner: owner)
            try await Task.sleep(for: .milliseconds(20))
        }
        let after = cachedPlayout(native), delta = after.since(before), audio = owner.snapshot
        let nativeReadbackFresh = (audio["snapshotUptime"] as? Double).map { $0 >= readbackAfter && $0 <= now } == true
        let physicalSilent = delta.energy <= 1e-9 && delta.nonSilentCallbacks == 0 && delta.callbacks == 0 &&
            audio["engineRunning"] as? Bool == false
        let passed = intentStayedOff && privateStateRetained && senderStayedMuted && nativeReadbackFresh && physicalSilent
        let result: [String: Any] = ["phase": phase, "step": step, "startedAt": began, "finishedAt": now,
            "seconds": now - began, "passed": passed, "intentStayedOff": intentStayedOff,
            "privateStateRetained": privateStateRetained, "senderStayedMuted": senderStayedMuted,
            "nativeReadbackFresh": nativeReadbackFresh, "physicalOutputSilent": physicalSilent,
            "nativeReadbackRequiredAfterUptime": readbackAfter,
            "logicalOutputEnabled": audio["outputEnabled"] as Any? ?? NSNull(),
            "logicalOutputRunning": audio["outputRunning"] as Any? ?? NSNull(),
            "logicalPlaying": audio["playing"] as Any? ?? NSNull(),
            "physicalCallbackDelta": delta.callbacks, "physicalEnergyDelta": delta.energy,
            "silenceEvidence": "no physical output callbacks or energy after drain; fresh applied output-off readback",
            "privateGraph": owner.privateInputGraphEvidenceForTesting, "physical": audio]
        emit("privateSoundQuietWindow", result)
        guard passed else { throw Failure("Isolated private Sound-off intent, privacy or physical-output qualification failed") }
        return result
    }
    private func privateSoundAction(_ enabled: Bool, model: NativeDesktopMeetingModel, native: NativeGuestEngine,
                                    owner: GuestSystemAudio, token: UInt64?, phase: String, step: String) async throws -> [String: Any] {
        guard model.snapshot.playoutOn != enabled, privateSoundCaptureClosed(model, native: native, owner: owner),
              privateSoundGraphValid(owner, token: token) else { throw Failure("Private Sound-cycle precondition failed") }
        let began = now
        emit("privateSoundActionBegin", ["phase": phase, "step": step, "enabled": enabled, "actionStart": began,
            "privateToken": token as Any? ?? NSNull(), "privateGraph": owner.privateInputGraphEvidenceForTesting])
        model.togglePlayout(); await model.waitForMediaActionsForTesting()
        let commandEnd = now, state = owner.snapshot
        guard model.snapshot.playoutOn == enabled, state["playoutEnabledRequested"] as? Bool == enabled,
              state["outputAvailable"] as? Bool == enabled, privateSoundGraphValid(owner, token: token),
              privateSoundCaptureClosed(model, native: native, owner: owner) else { throw Failure("Private Sound command was not applied safely") }
        var result: [String: Any] = ["phase": phase, "step": step, "enabled": enabled, "actionStart": began,
            "commandEnd": commandEnd, "commandSeconds": commandEnd - began, "privateToken": token as Any? ?? NSNull()]
        if enabled {
            try await wait(seconds: 3) {
                let playout = self.cachedPlayout(native), decoded = native.mediaSnapshot.audio
                return playout.lastNonSilentUptime.map { $0 >= began && self.now - $0 >= 0 && self.now - $0 < 0.2 } == true &&
                    decoded.lastNonSilentUptime.map { $0 >= began && self.now - $0 >= 0 && self.now - $0 < 0.2 } == true &&
                    self.privateSoundGraphValid(owner, token: token) && self.privateSoundCaptureClosed(model, native: native, owner: owner)
            }
            result["freshDecodedAndOutputObservedUptime"] = now
            let key = "private-sound-enabled-\(step)"
            beginWindow(key, native); let stableStart = now
            try await Task.sleep(for: .milliseconds(600))
            guard let window = windows.removeValue(forKey: key) else { throw Failure("Missing private Sound stable window") }
            window.sample(decoded: native.mediaSnapshot.audio, playout: cachedPlayout(native), at: now)
            let stable = window.result(at: now)
            let video = native.subscriber?.renderer.window(from: stableStart, to: now) ?? .invalid
            let videoPassed = video.complete && video.frames > 0 && video.maximumGap < 0.35 && video.endFrameAge.map { $0 < 0.2 } == true
            result["stableEnabledWindow"] = stable; result["video"] = video.evidence
            result["passed"] = stable["passed"] as? Bool == true && videoPassed && privateSoundGraphValid(owner, token: token) &&
                privateSoundCaptureClosed(model, native: native, owner: owner)
        } else {
            try await Task.sleep(for: .milliseconds(250))
            result["quietWindow"] = try await privateSoundQuietWindow(model, native: native, owner: owner,
                token: token, phase: phase, step: step, readbackAfter: began)
            result["passed"] = true
        }
        result["privateGraph"] = owner.privateInputGraphEvidenceForTesting
        result["physical"] = owner.snapshot
        emit("privateSoundActionEnd", result)
        guard result["passed"] as? Bool == true else { throw Failure("Private Sound enabled-window qualification failed") }
        return result
    }
    private func qualifyPreOptInPrivateRejection(_ adapter: NativeDesktopGuestEngine, model: NativeDesktopMeetingModel,
                                                native: NativeGuestEngine, peer: NativeStartupReceiverProxy) async throws {
        #if ROCK_COREAUDIO_DUPLEX_R6
        guard let owner = native.systemAudio, !owner.backend.usesAudioEngine,
              !model.snapshot.microphoneOn, LKRTCApplicationCaptureMuted() == 1 else {
            throw Failure("Pre-opt-in rejection requires muted R6 meeting")
        }
        let before = owner.duplexStartupEvidenceForTesting, beforeSnapshot = owner.snapshot
        let beforeMeter = owner.privateInputMeterEvidence
        guard before["enabled"] as? Bool == true, before["inputRunning"] as? Bool == false,
              before["captureCommitted"] as? Bool == false,
              beforeSnapshot["privateInputAdmissionRejectedBeforeHardware"] == nil else {
            throw Failure("Pre-opt-in rejection precondition is not fresh")
        }
        guard let operationsBefore = beforeSnapshot["audioOperations"] as? [Any],
              let receiptsBefore = beforeSnapshot["duplexPreparationReceipts"] as? [Any],
              let meterCallbacksBefore = beforeMeter["callbacks"] as? NSNumber else {
            throw Failure("Pre-opt-in rejection requires complete operation and meter evidence")
        }
        let remoteBefore = peer.mediaSnapshot.audio
        let health = PrivateCheckHealth()
        health.sample(peer: peer, model: model, owner: owner, at: now)
        beginWindow("preOptInPrivateRejection", native)
        var rejected = false
        do { try await adapter.startPrivateAudioCheck() }
        catch { rejected = true }
        let immediate = owner.snapshot
        let reason = immediate["privateInputUnsupportedReason"] as? String
        var closed = true, samples = 0
        let end = now + 2
        while now < end {
            let state = owner.duplexStartupEvidenceForTesting
            health.sample(peer: peer, model: model, owner: owner, at: now)
            closed = closed && !model.snapshot.microphoneOn && LKRTCApplicationCaptureMuted() == 1 &&
                state["inputRunning"] as? Bool == false && state["captureCommitted"] as? Bool == false &&
                state["transportQuarantined"] as? Bool == false
            samples += 1
            try await Task.sleep(for: .milliseconds(20))
        }
        let after = owner.duplexStartupEvidenceForTesting, afterSnapshot = owner.snapshot
        let unchangedKeys = ["ownerGeneration", "physicalGeneration", "activePrepareSerial", "inputCreateCount",
                             "inputStartCount", "outputCreateCount", "outputStartCount", "authority"]
        let unchanged = unchangedKeys.allSatisfy { key in
            guard let a = before[key] as? NSNumber, let b = after[key] as? NSNumber else { return false }
            return a == b
        }
        let noOperations = (afterSnapshot["audioOperations"] as? [Any]).map { NSArray(array: operationsBefore).isEqual(to: $0) } == true &&
            (afterSnapshot["duplexPreparationReceipts"] as? [Any]).map { NSArray(array: receiptsBefore).isEqual(to: $0) } == true
        let noMeter = meterCallbacksBefore == (owner.privateInputMeterEvidence["callbacks"] as? NSNumber)
        let remote = peer.mediaSnapshot.audio.since(remoteBefore)
        let noPCM = remote.nonSilentCallbacks == 0 && remote.energy <= 1e-9
        let advancingOutput = ((after["outputCallbacks"] as? NSNumber)?.uint64Value ?? 0) >
            ((before["outputCallbacks"] as? NSNumber)?.uint64Value ?? 0)
        let continuity = endWindow("preOptInPrivateRejection", native)
        let passed = rejected && reason == "borrowedBeforePersistentOptIn" &&
            immediate["privateInputAdmissionRejectedBeforeHardware"] as? Bool == true &&
            unchanged && noOperations && noMeter && noPCM && closed && samples > 0 && advancingOutput &&
            health.telemetryFresh && health.mutedThroughout && health.ownerMutedThroughout &&
            continuity["passed"] as? Bool == true
        emit("preOptInPrivateRejection", ["passed": passed, "reason": reason as Any? ?? NSNull(),
            "before": before, "after": after, "unchangedGenerationsAndIntent": unchanged,
            "noNativeOperations": noOperations, "noInputMeterCallbacks": noMeter,
            "noRemotePCM": noPCM, "captureStayedClosed": closed, "privacySamples": samples,
            "telemetryFresh": health.telemetryFresh, "maximumTelemetryAge": health.maximumTelemetryAge,
            "outputAdvanced": advancingOutput, "incoming": continuity])
        guard passed else { throw Failure("Pre-opt-in private rejection changed capture/output ownership") }
        #else
        throw Failure("Pre-opt-in rejection requires R6 diagnostic capability")
        #endif
    }

    /// A separate fallback case: Off precedes admission, not only an active check.
    private func qualifySoundOffPrivateAdmission(_ adapter: NativeDesktopGuestEngine, model: NativeDesktopMeetingModel,
                                                 native: NativeGuestEngine, peer: NativeStartupReceiverProxy) async throws {
        #if ROCK_VPIO_BUILTIN_RELEASE
        let phase = "sound-off-before-private-admission"
        guard let owner = native.systemAudio, owner.backend.usesAudioEngine, model.snapshot.playoutOn,
              owner.snapshot["inputAvailable"] as? Bool == false,
              owner.snapshot["stoppedInputPreparationResult"] as? Int == 0,
              privateSoundCaptureClosed(model, native: native, owner: owner), privateSoundGraphValid(owner, token: nil) else {
            throw Failure("Sound-off admission case requires completed stopped preparation before first microphone intent")
        }
        let prepared = owner.snapshot
        let off = try await privateSoundAction(false, model: model, native: native, owner: owner,
            token: nil, phase: phase, step: "off-before-admission")
        guard owner.nextPrivateInputCheckPathForTesting == .existing else {
            throw Failure("Sound-off private admission did not select the existing path before hardware")
        }
        let initial = peer.mediaSnapshot, initialTelemetry = peer.telemetryUptime, began = now
        guard initial.connected, !initial.failed, began - initialTelemetry >= 0, began - initialTelemetry < 0.25 else {
            throw Failure("Sound-off private admission receiver baseline is unavailable")
        }
        let baseline = initial.audio, outputBaseline = cachedPlayout(native)
        let health = PrivateCheckHealth()
        var outputStayedOff = true, senderStayedClosed = true
        var privateInputTransactionActive = false
        var maximumSampleWork: [String: Any] = [:]
        func sample() {
            let sampleBegan = now
            health.sample(peer: peer, model: model, owner: owner, at: now)
            let healthCompleted = now
            let physical = owner.snapshot, output = cachedPlayout(native).since(outputBaseline)
            outputStayedOff = outputStayedOff && !model.snapshot.playoutOn &&
                physical["playoutEnabledRequested"] as? Bool == false && physical["outputAvailable"] as? Bool == false &&
                output.callbacks == 0 && output.nonSilentCallbacks == 0 && output.energy <= 1e-9
            let outputCompleted = now
            senderStayedClosed = senderStayedClosed && privateSoundCaptureClosed(model, native: native, owner: owner,
                allowPrivateInput: privateInputTransactionActive)
            let completed = now
            if completed - sampleBegan > (maximumSampleWork["durationSeconds"] as? Double ?? -1) {
                maximumSampleWork = ["startedUptime": sampleBegan, "healthCompletedUptime": healthCompleted,
                    "outputCompletedUptime": outputCompleted, "completedUptime": completed,
                    "durationSeconds": completed - sampleBegan, "mainThread": Thread.isMainThread,
                    "privateInputTransactionActive": privateInputTransactionActive]
            }
        }
        sample()
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                sample()
            }
        }
        defer { watcher.cancel() }
        let startAt = now
        privateInputTransactionActive = true
        do { try await adapter.startPrivateAudioCheck() }
        catch {
            privateInputTransactionActive = false; sample()
            emit("privateSoundOffAdmissionResult", ["phase": phase, "passed": false, "stage": "start",
                "error": String(describing: error), "preparedBeforeOff": prepared, "off": off,
                "actualSelectedPrivateInputPath": owner.lastPrivateInputCheckPathForTesting?.rawValue as Any? ?? NSNull(),
                "transactionHealth": health.probe, "physical": owner.snapshot])
            throw error
        }
        let startCompleted = now
        guard owner.lastPrivateInputCheckPathForTesting == .existing else { throw Failure("Sound-off admission used an unexpected private path") }
        try await wait { (owner.privateInputMeterEvidence["lastCallbackUptime"] as? Double).map { $0 >= startAt } == true }
        let until = now + 2
        while now < until { try await Task.sleep(for: .milliseconds(20)) }
        let meter = owner.privateInputMeterEvidence, meterObserved = now
        let inputFresh = (meter["lastCallbackUptime"] as? Double).map { $0 >= startAt && $0 <= meterObserved && meterObserved - $0 < 0.25 } == true
        let endAt = now
        var ending: Task<Void, Error>?, endReturned: Double?
        await withCheckedContinuation { entered in
            ending = Task { @MainActor in
                entered.resume(); defer { endReturned = self.now }
                try await adapter.stopPrivateAudioCheck()
            }
        }
        await Task.yield()
        let instantMeter = owner.privateInputMeterEvidence
        let revoked = adapter.privateAudioLevel == nil && instantMeter["enabled"] as? Bool != true
        var endError: String?
        do { try await ending?.value } catch { endError = String(describing: error) }
        let endCompleted = endReturned ?? now
        privateInputTransactionActive = false; sample()
        try await wait(seconds: 1) { peer.telemetryUptime > endCompleted && self.now - endCompleted >= 0.2 }
        sample(); watcher.cancel(); await watcher.value
        let final = peer.mediaSnapshot, observed = now, finalTelemetry = peer.telemetryUptime
        let received = final.audio.since(baseline), physical = owner.snapshot
        let checks: [String: Bool] = ["actualExistingPath": owner.lastPrivateInputCheckPathForTesting == .existing,
            "outputStayedOff": outputStayedOff, "senderStayedClosed": senderStayedClosed,
            "mutedThroughout": health.mutedThroughout && health.ownerMutedThroughout,
            "receiverFreshThroughout": health.telemetryFresh && final.connected && !final.failed &&
                finalTelemetry > endCompleted && observed >= finalTelemetry && observed - finalTelemetry < 0.25,
            "sampleGapsBounded": health.maximumSampleGap < 0.25, "inputFresh": inputFresh,
            "zeroRemotePrivateAudio": received.energy <= 1e-9 && received.nonSilentCallbacks == 0,
            "meterRevokedOnFirstYield": revoked, "stopWithinTwoSeconds": endCompleted - endAt <= 2,
            "stopSucceeded": endError == nil, "inputAvailabilityRestored": physical["inputAvailable"] as? Bool == false,
            "engineStoppedWhileOff": physical["engineRunning"] as? Bool == false,
            "freshStoppedReadback": (physical["snapshotUptime"] as? Double).map { $0 >= endAt && $0 <= observed } == true,
            "isolatedGraphStillStopped": privateSoundGraphValid(owner, token: nil)]
        var result: [String: Any] = ["phase": phase, "checks": checks, "passed": checks.values.allSatisfy { $0 },
            "preparedBeforeOff": prepared, "off": off, "actualSelectedPrivateInputPath": owner.lastPrivateInputCheckPathForTesting?.rawValue as Any? ?? NSNull(),
            "startCommandSeconds": startCompleted - startAt, "endCommandSeconds": endCompleted - endAt,
            "endError": endError as Any? ?? NSNull(), "input": meter, "physicalAfterStop": physical,
            "maximumSampleWork": maximumSampleWork, "maximumSenderTrackQuery": native.maximumAudioSenderTrackQueryForTesting,
            "maximumMainActorIntervalSeconds": maximumMainInterval,
            "maximumMainActorGapStartUptime": mainGapStart as Any? ?? NSNull(), "maximumMainActorGapEndUptime": mainGapEnd as Any? ?? NSNull(),
            "transactionHealth": health.probe, "remoteEnergy": received.energy, "remoteNonSilentCallbacks": received.nonSilentCallbacks,
            "intentionalOffContinuityPolicy": "no output callbacks after drain; enabled media continuity measured after restore"]
        emit("privateSoundOffAdmissionStopped", result)
        guard checks.values.allSatisfy({ $0 }) else {
            emit("privateSoundOffAdmissionResult", result)
            throw Failure("Sound-off private admission privacy, output-off or stop qualification failed")
        }
        result["restore"] = try await privateSoundAction(true, model: model, native: native, owner: owner,
            token: nil, phase: phase, step: "restore-after-existing-private-stop")
        let renewal = owner.snapshot
        guard renewal["stoppedInputRenewalOutcome"] as? String == "prepared",
              renewal["stoppedInputRenewalNativeResult"] as? Int == 0 else {
            throw Failure("Sound-off private flow restored without a confirmed fresh stopped resource")
        }
        result["stoppedInputRenewal"] = renewal["stoppedInputRenewalReceipt"] as Any? ?? NSNull()
        result["restoredFreshMedia"] = true
        emit("privateSoundOffAdmissionResult", result)
        #else
        throw Failure("Sound-off private admission case requires the typed VPIO build policy")
        #endif
    }

    private func qualifyPrivateCheck(_ adapter: NativeDesktopGuestEngine, model: NativeDesktopMeetingModel,
                                     native: NativeGuestEngine, peer: NativeStartupReceiverProxy, phase: String) async throws {
        guard !model.snapshot.microphoneOn, LKRTCApplicationCaptureMuted() == 1 else { throw Failure("Private check must start muted") }
        guard let owner = native.systemAudio else { throw Failure("Private check physical owner is unavailable") }
        func meterNow(isolated: Bool) -> Double {
            guard isolated else { return now }
            var value = timespec(); clock_gettime(CLOCK_UPTIME_RAW, &value)
            return Double(value.tv_sec) + Double(value.tv_nsec) / 1e9
        }
        try await Task.sleep(for: .seconds(1)) // Drain already received pre-mute media before the no-leak window.
        let initial = peer.mediaSnapshot, initialTelemetry = peer.telemetryUptime, began = now
        guard initial.connected, !initial.failed, began - initialTelemetry >= 0,
              began - initialTelemetry < 0.25 else { throw Failure("Private check receiver telemetry is unavailable") }
        let baseline = initial.audio
        guard let inputBefore = owner.snapshot["inputAvailable"] as? Bool else {
            throw Failure("Private check input availability is unknown")
        }
        let expectedPrivatePath = owner.nextPrivateInputCheckPathForTesting
        let isolatedRequested = expectedPrivatePath == .isolated
        #if ROCK_VPIO_BUILTIN_RELEASE
        guard inputBefore || isolatedRequested else {
            throw Failure("Typed-policy private-before-first qualification requires eligible isolated admission; fallback needs its separate case")
        }
        #endif
        let isolated = isolatedRequested && owner.backend.usesAudioEngine && !inputBefore
        let soundCycle = ProcessInfo.processInfo.environment["ROCK_MIC_PRIVATE_SOUND_CYCLE"] == "1" && phase == "before-first-0"
        let outputOnAtAdmission = soundCycle && model.snapshot.playoutOn && owner.snapshot["playoutEnabledRequested"] as? Bool == true &&
            owner.snapshot["outputAvailable"] as? Bool == true && owner.snapshot["engineRunning"] as? Bool == true &&
            cachedPlayout(native).lastNonSilentUptime.map { self.now >= $0 && self.now - $0 < 0.2 } == true
        guard !soundCycle || (isolated && outputOnAtAdmission) else {
            throw Failure("Private Sound cycle requires isolated input and normally running meeting output at private admission")
        }
        let soundAdmission: [String: Any] = soundCycle ? ["sampleUptime": now, "modelSoundOn": model.snapshot.playoutOn,
            "physical": owner.snapshot, "physicalOutput": owner.playoutMeterEvidence] : [:]
        let inputBegan = meterNow(isolated: isolated), graphBefore = owner.privateInputGraphEvidenceForTesting
        guard !isolated || !graphBefore.isEmpty else {
            throw Failure("Isolated private check requires a stopped meeting input and available graph diagnostics")
        }
        let windowKey = "private-\(phase)"
        beginWindow(windowKey, native)
        let health = PrivateCheckHealth()
        var requiredPrivateToken: UInt64?
        health.sample(peer: peer, model: model, owner: owner, at: now)
        let healthWatcher = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                health.sample(peer: peer, model: model, owner: owner, at: self.now, requiredPrivateToken: requiredPrivateToken)
            }
        }
        defer { healthWatcher.cancel() }
        let startCommandStart = now
        do { try await adapter.startPrivateAudioCheck() }
        catch {
            emit("privateCheckStartCommand", ["phase": phase, "startedAt": startCommandStart, "finishedAt": now,
                "seconds": now - startCommandStart, "succeeded": false, "error": String(describing: error),
                "privateGraphBefore": graphBefore, "privateGraphAfter": owner.privateInputGraphEvidenceForTesting])
            throw error
        }
        let startCommandEnd = now, graphActive = owner.privateInputGraphEvidenceForTesting
        let actualPrivatePath = owner.lastPrivateInputCheckPathForTesting
        guard actualPrivatePath == expectedPrivatePath else { throw Failure("Private admission selected a different path than its qualification baseline") }
        let isolatedGraphObserved = !isolated || (graphActive["active"] as? Bool == true && graphActive["inputRunning"] as? Bool == true &&
            graphActive["startInFlight"] as? Bool == false && graphActive["cleanupUnconfirmed"] as? Bool == false)
        emit("privateCheckStartCommand", ["phase": phase, "startedAt": startCommandStart, "finishedAt": startCommandEnd,
            "seconds": startCommandEnd - startCommandStart, "succeeded": true,
            "expectedPrivateInputPath": expectedPrivatePath.rawValue, "actualSelectedPrivateInputPath": actualPrivatePath?.rawValue as Any? ?? NSNull(),
            "privateGraphBefore": graphBefore, "privateGraphAfter": graphActive])
        try await wait { (owner.privateInputMeterEvidence["lastCallbackUptime"] as? Double).map { $0 >= inputBegan } == true }
        let end = now + 2
        while now < end {
            try await Task.sleep(for: .milliseconds(20))
        }
        var soundProbe: [String: Any] = [:]
        var outputBeforePrivateEnd: GuestAudioSnapshot?
        if soundCycle {
            let token = (graphActive["token"] as? NSNumber)?.uint64Value ?? 0
            guard token > 0, privateSoundGraphValid(owner, token: token) else { throw Failure("Private Sound cycle has no live isolated token") }
            requiredPrivateToken = token
            health.sample(peer: peer, model: model, owner: owner, at: now, requiredPrivateToken: token)
            let beforeEnabled = windows[windowKey]?.result(at: now) ?? ["passed": false]
            guard beforeEnabled["passed"] as? Bool == true else { throw Failure("Private Sound cycle lacks stable enabled decode/output before Off") }
            emit("privateSoundCycleEntered", ["phase": phase, "privateToken": token,
                "outputOnAtPrivateAdmission": outputOnAtAdmission, "admission": soundAdmission,
                "enabledReceiveWindowBeforeOff": beforeEnabled])
            let off = try await privateSoundAction(false, model: model, native: native, owner: owner,
                token: token, phase: phase, step: "off-while-private")
            let on = try await privateSoundAction(true, model: model, native: native, owner: owner,
                token: token, phase: phase, step: "on-same-private-token")
            let offBeforeEnd = try await privateSoundAction(false, model: model, native: native, owner: owner,
                token: token, phase: phase, step: "off-before-private-end")
            outputBeforePrivateEnd = cachedPlayout(native)
            soundProbe = ["enabled": true, "privateToken": token, "outputOnAtPrivateAdmission": outputOnAtAdmission,
                "admission": soundAdmission,
                "enabledReceiveWindowBeforeOff": beforeEnabled, "off": off, "on": on, "offBeforePrivateEnd": offBeforeEnd,
                "decodeAndPhysicalContinuityPolicy": "stable enabled windows; intentional Off intervals excluded because output drives decoder pulls",
                "wholeWindowContinuityPolicy": "video and UI; private input, mute and receiver health remain sampled throughout"]
        }
        let meter = owner.privateInputMeterEvidence, inputObserved = meterNow(isolated: isolated)
        let inputFresh = (meter["lastCallbackUptime"] as? Double).map { $0 >= inputBegan && inputObserved - $0 >= 0 && inputObserved - $0 < 0.25 } == true
        let inputEnergy = (meter["energy"] as? NSNumber)?.doubleValue ?? 0
        let inputNonzero = inputEnergy.isFinite && inputEnergy > 0 && ((meter["nonSilentCallbacks"] as? NSNumber)?.intValue ?? 0) > 0
        let muted = health.mutedThroughout && health.ownerMutedThroughout && !model.snapshot.microphoneOn && LKRTCApplicationCaptureMuted() == 1 &&
            owner.snapshot["microphoneMuted"] as? Bool == true
        emit("privateCheckWindowObserved", ["phase": phase, "meetingMuted": muted, "inputFresh": inputFresh,
            "receiverTelemetryFresh": health.telemetryFresh, "remoteEnergy": peer.mediaSnapshot.audio.since(baseline).energy,
            "inputBefore": inputBefore, "privateGraphActive": graphActive])
        requiredPrivateToken = nil
        let endCommandStart = now
        var ending: Task<Void, Error>?
        var endReturnedAt: Double?
        // The handshake proves that the end task entered before the sampler
        // yields. A very fast stop must still leave the consumer meter revoked.
        await withCheckedContinuation { entered in
            ending = Task { @MainActor in
                entered.resume()
                defer { endReturnedAt = self.now }
                try await adapter.stopPrivateAudioCheck()
            }
        }
        await Task.yield()
        let revokeSampleAt = now, instantMeter = owner.privateInputMeterEvidence
        let instantGraph = owner.privateInputGraphEvidenceForTesting
        let instantLevelRevoked = adapter.privateAudioLevel == nil
        let instantMeterRevoked = instantLevelRevoked && instantMeter["enabled"] as? Bool != true
        var endError: String?
        do { try await ending?.value } catch { endError = String(describing: error) }
        let endCommandEnd = endReturnedAt ?? now, graphAfter = owner.privateInputGraphEvidenceForTesting
        let endBudgetMet = endCommandEnd - endCommandStart <= 2
        let inputAfter = owner.snapshot["inputAvailable"] as? Bool
        let mutedAfterEnd = !model.snapshot.microphoneOn && LKRTCApplicationCaptureMuted() == 1 && owner.snapshot["microphoneMuted"] as? Bool == true
        let inputRestored = inputAfter == inputBefore &&
            (inputBefore || owner.backend.usesAudioEngine != false || owner.snapshot["inputRunning"] as? Bool == false)
        let graphStopped = !isolated || (graphAfter["active"] as? Bool == false && graphAfter["startInFlight"] as? Bool == false &&
            graphAfter["inputRunning"] as? Bool == false && graphAfter["cleanupUnconfirmed"] as? Bool == false &&
            graphAfter["confirmedStopped"] as? Bool == true)
        if soundCycle {
            guard graphStopped, inputRestored, !model.snapshot.playoutOn, owner.snapshot["playoutEnabledRequested"] as? Bool == false else {
                throw Failure("Ending private capture changed the explicit Sound-off intent")
            }
            soundProbe["offAcrossPrivateEnd"] = try await privateSoundQuietWindow(model, native: native, owner: owner,
                token: nil, phase: phase, step: "off-across-private-end", readbackAfter: endCommandStart,
                baseline: outputBeforePrivateEnd)
            soundProbe["restoreAfterPrivateEnd"] = try await privateSoundAction(true, model: model, native: native, owner: owner,
                token: nil, phase: phase, step: "restore-before-real-microphone")
            let finalPhysical = owner.snapshot
            let restoredChecks: [String: Bool] = ["modelSoundOn": model.snapshot.playoutOn,
                "outputDesiredOn": finalPhysical["playoutEnabledRequested"] as? Bool == true,
                "outputAvailable": finalPhysical["outputAvailable"] as? Bool == true,
                "inputAvailabilityRestored": finalPhysical["inputAvailable"] as? Bool == inputBefore,
                "privateGraphStopped": privateSoundGraphValid(owner, token: nil),
                "privateTokenMaintainedThroughout": health.requiredPrivateTokenMaintained,
                "privateInputFreshThroughout": health.requiredPrivateInputFresh,
                "privateTokenSamplesObserved": health.requiredPrivateTokenSamples > 0]
            let restored = restoredChecks.values.allSatisfy { $0 }
            soundProbe["finalPredicates"] = restoredChecks
            soundProbe["failedFinalPredicates"] = restoredChecks.filter { !$0.value }.keys.sorted()
            soundProbe["transactionHealth"] = health.probe
            soundProbe["finalPhysical"] = finalPhysical
            soundProbe["finalPrivateGraph"] = owner.privateInputGraphEvidenceForTesting
            soundProbe["passed"] = restored
            emit("privateSoundCycleResult", soundProbe.merging(["phase": phase]) { _, new in new })
            guard restored else { throw Failure("Private Sound cycle did not restore output independently of the stopped private graph") }
        }
        // Include teardown in the cumulative zero-leak interval and require a
        // fresh receiver observation produced after end returned.
        try await wait(seconds: 1) { peer.telemetryUptime > endCommandEnd && self.now - endCommandEnd >= 0.2 }
        let final = peer.mediaSnapshot, finalTelemetry = peer.telemetryUptime, finalAge = now - finalTelemetry
        let received = final.audio.since(baseline)
        health.sample(peer: peer, model: model, owner: owner, at: now)
        healthWatcher.cancel(); await healthWatcher.value
        let telemetryFresh = health.telemetryFresh && final.connected && !final.failed && finalAge >= 0 && finalAge < 0.25 && finalTelemetry > endCommandEnd
        let incoming: [String: Any]
        if let window = windows.removeValue(forKey: windowKey) {
            window.sample(decoded: native.mediaSnapshot.audio, playout: cachedPlayout(native), at: now)
            incoming = window.result(at: now)
        } else { incoming = ["passed": false] }
        let video = native.subscriber?.renderer.window(from: began, to: now) ?? .invalid
        let videoPassed = video.complete && video.frames > 0 && video.maximumGap < 0.35 && video.endFrameAge.map { $0 < 0.2 } == true
        let mainPassed = (incoming["mainActorMaximumSeconds"] as? Double ?? .infinity) < 0.35
        let soundPassed = soundProbe["passed"] as? Bool == true
        let continuityPassed = soundCycle ? (mainPassed && videoPassed && soundPassed) :
            (incoming["passed"] as? Bool == true && videoPassed)
        emit("privateCheckEndCommand", ["phase": phase, "startedAt": endCommandStart, "finishedAt": endCommandEnd,
            "seconds": endCommandEnd - endCommandStart, "succeeded": endError == nil, "error": endError as Any? ?? NSNull(),
            "withinTwoSecondBudget": endBudgetMet, "revokeSampleUptime": revokeSampleAt,
            "meterRevokedAfterFirstYield": instantMeterRevoked, "levelRevokedAfterFirstYield": instantLevelRevoked,
            "instantMeter": instantMeter, "privateGraphAtRevokeSample": instantGraph, "privateGraphAfter": graphAfter])
        emit("privateCheckNoLeak", ["phase": phase, "meetingMuted": muted && mutedAfterEnd, "remoteEnergy": received.energy,
            "remoteNonSilentCallbacks": received.nonSilentCallbacks, "input": meter, "inputFresh": inputFresh,
            "inputNonzeroObserved": inputNonzero, "nonzeroRawInputRequired": isolated,
            "inputTimestampClock": isolated ? "CLOCK_UPTIME_RAW" : "systemUptime", "inputBegan": inputBegan, "inputObserved": inputObserved,
            "receiverTelemetryFresh": telemetryFresh, "maximumTelemetryAgeSeconds": health.maximumTelemetryAge,
            "initialTelemetryUptime": initialTelemetry, "finalTelemetryUptime": finalTelemetry, "healthSamples": health.samples,
            "transactionHealth": health.probe,
            "inputBefore": inputBefore, "inputAfter": inputAfter as Any? ?? NSNull(), "inputAvailabilityRestored": inputRestored,
            "isolatedRequested": isolatedRequested, "isolated": isolated, "isolatedGraphObserved": isolatedGraphObserved,
            "expectedPrivateInputPath": expectedPrivatePath.rawValue, "actualSelectedPrivateInputPath": actualPrivatePath?.rawValue as Any? ?? NSNull(),
            "privateGraphStopped": graphStopped, "privateGraphBefore": graphBefore,
            "privateGraphActive": graphActive, "privateGraphAfter": graphAfter, "incoming": incoming,
            "video": video.evidence, "continuityPassed": continuityPassed,
            "privateSoundCycle": soundProbe,
            "startCommandSeconds": startCommandEnd - startCommandStart, "endCommandSeconds": endCommandEnd - endCommandStart,
            "meterRevokedAfterFirstYield": instantMeterRevoked, "withinTwoSecondEndBudget": endBudgetMet])
        guard endError == nil, muted, health.mutedThroughout, health.ownerMutedThroughout, mutedAfterEnd, health.maximumSampleGap < 0.25,
              inputFresh, telemetryFresh, inputRestored, received.energy <= 1e-9,
              received.nonSilentCallbacks == 0, !isolated || (inputNonzero && isolatedGraphObserved && graphStopped && instantMeterRevoked && endBudgetMet && continuityPassed) else {
            throw Failure("Private input check privacy or telemetry qualification failed")
        }
    }
    private func leaveDuringPrivateStart(_ model: NativeDesktopMeetingModel, adapter: NativeDesktopGuestEngine,
                                        native: NativeGuestEngine, peer: NativeStartupReceiverProxy) async throws {
        let id = UUID().uuidString, scenario = "leave-during-private-start"
        emit("privateStartLeaveCaseEntered", ["id": id, "scenario": scenario])
#if ROCK_PRIVATE_INPUT_EXPERIMENT || ROCK_VPIO_BUILTIN_RELEASE
        guard let owner = native.systemAudio, owner.backend.usesAudioEngine,
              owner.nextPrivateInputCheckPathForTesting == .isolated,
              owner.snapshot["inputAvailable"] as? Bool == false,
              !model.snapshot.microphoneOn, !model.snapshot.cameraOn, LKRTCApplicationCaptureMuted() == 1 else {
            throw Failure("Private-start Leave fault requires isolated input before first microphone activation")
        }
        // Keep only this SDK handle alive for passive state readback after Leave
        // retires the owner factory. It is released when this helper returns.
        let retainedModule = owner.factory.audioDeviceModule
        let graphBefore = retainedModule.privateInputMeterState as? [String: Any] ?? [:]
        guard graphBefore["supported"] as? Bool == true else { throw Failure("Private input SDK state is unsupported") }
        try await Task.sleep(for: .seconds(1))
        let initial = peer.mediaSnapshot, baseline = initial.audio, initialTelemetry = peer.telemetryUptime
        guard initial.connected, !initial.failed, now - initialTelemetry >= 0, now - initialTelemetry < 0.25 else {
            throw Failure("Private-start Leave receiver baseline is unavailable")
        }
        let health = PrivateCheckHealth()
        var afterBarrier = false, gateOpened = false, meterReopened = false, graphReopened = false
        var privacySamples = 0
        func sample() {
            health.sample(peer: peer, model: model, owner: owner, at: now)
            guard afterBarrier else { return }
            privacySamples += 1
            gateOpened = gateOpened || LKRTCApplicationCaptureMuted() != 1 || model.snapshot.microphoneOn || model.microphoneStarting
            meterReopened = meterReopened || owner.privateInputLevel != nil || adapter.privateAudioLevel != nil ||
                owner.privateInputMeterEvidence["enabled"] as? Bool == true
            let graph = retainedModule.privateInputMeterState as? [String: Any] ?? [:]
            graphReopened = graphReopened || graph["active"] as? Bool == true
        }
        sample()
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                sample()
            }
        }
        defer { watcher.cancel() }
        var startFinished = false, startReturnedAt: Double?
        let startRequestedAt = now
        let starting = Task { @MainActor () -> (succeeded: Bool, error: String?) in
            defer { startFinished = true; startReturnedAt = self.now }
            do { try await adapter.startPrivateAudioCheck(); return (true, nil) }
            catch { return (false, String(describing: error)) }
        }
        defer { starting.cancel() }
        let observeDeadline = now + 5
        var operation: [String: Any] = [:], graphAtObservation: [String: Any] = [:]
        while now < observeDeadline, !startFinished {
            let active = owner.snapshot["audioActiveOperation"] as? [String: Any] ?? [:]
            let graph = retainedModule.privateInputMeterState as? [String: Any] ?? [:]
            let token = (graph["token"] as? NSNumber)?.uint64Value ?? 0
            let revoked = (graph["revokedThroughToken"] as? NSNumber)?.uint64Value ?? 0
            if active["nativeCall"] as? String == "start-private-input-meter", active["stage"] as? String == "native-call",
               graph["supported"] as? Bool == true, graph["startInFlight"] as? Bool == true,
               graph["requested"] as? Bool == true, token > 0, revoked < token {
                operation = active; graphAtObservation = graph; break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard !operation.isEmpty else {
            starting.cancel(); _ = await starting.value
            try? await adapter.stopPrivateAudioCheck()
            emit("privateStartLeaveCaseResult", ["id": id, "scenario": scenario, "nativeOverlapProven": false,
                "testEntered": true, "startCompletedBeforeObservation": startFinished, "passed": false,
                "reason": "No actual private native start overlap was observed", "privateGraphBefore": graphBefore,
                "privateGraphAfter": retainedModule.privateInputMeterState])
            _ = await cleanup()
            throw Failure("Private-start Leave overlap was not observed; case was not qualified")
        }
        guard owner.lastPrivateInputCheckPathForTesting == .isolated else {
            throw Failure("Private-start Leave observed work from an unexpected admission path")
        }
        let observedAt = now, captureBefore = LKRTCApplicationCaptureState()
        let observedToken = (graphAtObservation["token"] as? NSNumber)?.uint64Value ?? 0
        var privacyBefore = 0.0, privacyAfter = 0.0, leaving: Task<Bool, Never>?
        var preLatchGraph: [String: Any] = [:], liveAtLeaveIntent = false
        await withCheckedContinuation { entered in
            leaving = Task { @MainActor in
                preLatchGraph = retainedModule.privateInputMeterState as? [String: Any] ?? [:]
                liveAtLeaveIntent = (preLatchGraph["token"] as? NSNumber)?.uint64Value == observedToken && observedToken > 0 &&
                    ((preLatchGraph["revokedThroughToken"] as? NSNumber)?.uint64Value ?? 0) < observedToken &&
                    preLatchGraph["requested"] as? Bool == true && preLatchGraph["startInFlight"] as? Bool == true
                privacyBefore = self.now
                afterBarrier = true
                entered.resume()
                return await model.leave()
            }
        }
        await Task.yield()
        let firstYieldSampleAt = now
        let immediateGateMuted = LKRTCApplicationCaptureMuted() == 1
        let immediateMeterRevoked = owner.privateInputLevel == nil && adapter.privateAudioLevel == nil &&
            owner.privateInputMeterEvidence["enabled"] as? Bool != true
        let revokeDeadline = now + 2
        var revocationObserved = false, graphAtRevocation: [String: Any] = [:]
        while now < revokeDeadline {
            let graph = retainedModule.privateInputMeterState as? [String: Any] ?? [:]
            let phase = model.snapshot.phase
            if ((graph["revokedThroughToken"] as? NSNumber)?.uint64Value ?? 0) >= observedToken,
               graph["requested"] as? Bool == false, graph["active"] as? Bool == false,
               phase == .leaving || phase == .left, LKRTCApplicationCaptureMuted() == 1 {
                privacyAfter = now; graphAtRevocation = graph; revocationObserved = true; break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        if !revocationObserved { privacyAfter = now }
        sample()
        emit("privateStartLeavePrivacyBarrier", ["id": id, "scenario": scenario, "observedAt": observedAt,
            "privacyLatchBefore": privacyBefore, "privacyLatchAfter": privacyAfter,
            "actualSDKRevocationObserved": revocationObserved, "liveRequestedTokenAtLeaveIntent": liveAtLeaveIntent,
            "firstYieldSampleUptime": firstYieldSampleAt, "privateGraphAtLeaveIntent": preLatchGraph,
            "privateGraphAtRevocation": graphAtRevocation,
            "captureStateBefore": String(captureBefore), "captureStateAfter": String(LKRTCApplicationCaptureState()),
            "immediateGateMuted": immediateGateMuted, "immediateMeterRevoked": immediateMeterRevoked,
            "operationAtObservation": operation, "privateGraphAtObservation": graphAtObservation,
            "privateGraphAfterBarrier": retainedModule.privateInputMeterState])
        let startResult = await starting.value
        let left = await leaving?.value ?? false, leaveReturnedAt = now
        try await wait(seconds: 2) { peer.telemetryUptime > leaveReturnedAt && self.now - leaveReturnedAt >= 0.2 }
        sample(); watcher.cancel(); await watcher.value
        let audio = owner.snapshot, graphAfter = retainedModule.privateInputMeterState as? [String: Any] ?? [:]
        let finishedOperation = (audio["audioOperations"] as? [[String: Any]] ?? []).first { $0["id"] as? Int == operation["id"] as? Int }
        let calls = finishedOperation?["nativeCalls"] as? [[String: Any]] ?? []
        let overlap = liveAtLeaveIntent && revocationObserved && calls.contains { call in
            guard call["name"] as? String == "start-private-input-meter", let began = call["startedAt"] as? Double,
                  let seconds = call["seconds"] as? Double else { return false }
            return began < privacyBefore && began + seconds > privacyAfter
        }
        let stopped = graphAfter["supported"] as? Bool == true && graphAfter["confirmedStopped"] as? Bool == true &&
            graphAfter["active"] as? Bool == false && graphAfter["startInFlight"] as? Bool == false &&
            graphAfter["inputRunning"] as? Bool == false && graphAfter["cleanupUnconfirmed"] as? Bool == false
        let revoked = observedToken > 0 && ((graphAfter["revokedThroughToken"] as? NSNumber)?.uint64Value ?? 0) >= observedToken
        let meterRevoked = owner.privateInputLevel == nil && adapter.privateAudioLevel == nil && owner.privateInputMeterEvidence["enabled"] as? Bool != true
        let receiver = peer.mediaSnapshot, telemetryAge = now - peer.telemetryUptime
        let received = receiver.audio.since(baseline)
        let noLeak = health.telemetryFresh && health.maximumSampleGap < 0.25 && receiver.connected && !receiver.failed && telemetryAge >= 0 && telemetryAge < 0.25 &&
            received.energy <= 1e-9 && received.nonSilentCallbacks == 0
        let ownerCleanup = left && audio["cleanupSucceeded"] as? Bool == true && audio["inputAvailable"] as? Bool == false &&
            !native.hasPeerConnectionsForTesting && adapter.currentNativeEngine == nil && model.snapshot.phase == .left
        let privacy = immediateGateMuted && immediateMeterRevoked && LKRTCApplicationCaptureMuted() == 1 &&
            health.mutedThroughout && health.ownerMutedThroughout && !gateOpened && !meterReopened && !graphReopened && meterRevoked
        let passed = overlap && stopped && revoked && noLeak && ownerCleanup && privacy
        acceptance = acceptance && passed
        emit("privateStartLeaveCaseResult", ["id": id, "scenario": scenario, "testEntered": true, "passed": passed,
            "nativeOverlapProven": overlap, "privacyLatchBefore": privacyBefore, "privacyLatchAfter": privacyAfter,
            "actualSDKRevocationObserved": revocationObserved, "liveRequestedTokenAtLeaveIntent": liveAtLeaveIntent,
            "firstYieldSampleUptime": firstYieldSampleAt, "privateGraphAtLeaveIntent": preLatchGraph,
            "privateGraphAtRevocation": graphAtRevocation,
            "startRequestedAt": startRequestedAt, "startReturnedAt": startReturnedAt as Any? ?? NSNull(),
            "startSucceeded": startResult.succeeded, "startError": startResult.error as Any? ?? NSNull(), "leaveReturnedAt": leaveReturnedAt,
            "observedToken": observedToken, "tokenRevoked": revoked, "graphStopped": stopped, "consumerMeterRevoked": meterRevoked,
            "immediateGateMuted": immediateGateMuted, "immediateMeterRevoked": immediateMeterRevoked,
            "gateReopenedAfterBarrier": gateOpened, "meterReopenedAfterBarrier": meterReopened, "graphReopenedAfterBarrier": graphReopened,
            "privacySamples": privacySamples, "ownerCleanupConfirmed": ownerCleanup, "inputAvailable": audio["inputAvailable"] as Any? ?? NSNull(),
            "privateGraphBefore": graphBefore, "privateGraphAtObservation": graphAtObservation, "privateGraphAfter": graphAfter,
            "completedStartOperation": finishedOperation as Any? ?? NSNull(), "transactionHealth": health.probe,
            "receiverTelemetryAgeSeconds": telemetryAge, "remoteEnergy": received.energy, "remoteNonSilentCallbacks": received.nonSilentCallbacks,
            "speechClassified": false, "physical": audio])
        let clean = await cleanup()
        guard passed, clean else { throw Failure("Private-start Leave privacy, overlap or cleanup qualification failed") }
#else
        throw Failure("Private-start Leave fault requires the DEBUG private input SDK experiment")
#endif
    }
    private func leaveDuringWarmup(_ model: NativeDesktopMeetingModel, adapter: NativeDesktopGuestEngine) async throws {
        let joining = Task { try await model.connect() }
        try await wait {
            let active = adapter.currentNativeEngine?.systemAudio?.snapshot["audioActiveOperation"] as? [String: Any]
            return active?["nativeCall"] as? String == "prewarm-stopped-input"
        }
        guard let native = adapter.currentNativeEngine else { throw Failure("No warmup owner") }
        releasedNative = native
        let peersAbsent = !native.hasPeerConnectionsForTesting
        let mutation = now
        let left = await model.leave()
        _ = try? await joining.value
        let audio = native.systemAudio?.snapshot ?? [:]
        let safe = left && !native.hasPeerConnectionsForTesting &&
            LKRTCApplicationCaptureMuted() == 1 && !model.snapshot.microphoneOn &&
            audio["cleanupSucceeded"] as? Bool == true && (audio["meterGraphOwners"] as? Int ?? -1) == 0
        emit("warmupLeave", ["mutationUptime": mutation, "noPeersAtCancellation": peersAbsent, "noPeersAfterLeave": !native.hasPeerConnectionsForTesting,
            "physical": audio, "safetyChecksPassed": safe, "requiresRetainedSDKLogReview": true])
        guard await cleanup(), safe else { throw Failure("Leave during stopped preparation failed") }
    }
    private func soundOffDuringWarmup(_ model: NativeDesktopMeetingModel, adapter: NativeDesktopGuestEngine) async throws {
        let joinStart = now, joining = Task { try await model.connect() }
        do {
            var operation: [String: Any] = [:]
            try await wait {
                let active = adapter.currentNativeEngine?.systemAudio?.snapshot["audioActiveOperation"] as? [String: Any] ?? [:]
                guard active["nativeCall"] as? String == "prewarm-stopped-input" else { return false }
                operation = active; return true
            }
            guard let native = adapter.currentNativeEngine else { throw Failure("No warmup owner") }
            releasedNative = native
            guard model.snapshot.playoutOn,
                  native.systemAudio?.snapshot["playoutEnabledRequested"] as? Bool != false else {
                throw Failure("Sound must initially be On so the actual model toggle requests Off")
            }
            let id = UUID().uuidString, mutation = now
            LKRTCLogEx(.info, "MIC_FAULT mutation id=\(id) scenario=sound-off-during-warmup uptime=\(mutation)")
            emit("warmupSoundOffBegin", ["id": id, "operation": operation, "mutationUptime": mutation,
                "modelPlayoutBeforeAction": model.snapshot.playoutOn])
            model.togglePlayout()
            try await wait(seconds: 2) { native.systemAudio?.snapshot["playoutEnabledRequested"] as? Bool == false }
            let latchedAt = now
            let activeAtLatch = native.systemAudio?.snapshot["audioActiveOperation"] as? [String: Any] ?? [:]
            let overlapObserved = activeAtLatch["id"] as? Int == operation["id"] as? Int &&
                activeAtLatch["nativeCall"] as? String == "prewarm-stopped-input"
            try await joining.value; await model.waitForMediaActionsForTesting()
            let joinedAt = now
            // Let any pre-existing callback drain, then require a quiet physical
            // output window. Raw WebRTC playing/outputRunning remain demand only.
            try await Task.sleep(for: .milliseconds(250))
            let offBaseline = cachedPlayout(native), offStart = now
            try await Task.sleep(for: .milliseconds(700))
            let offFresh = await native.systemAudio?.refreshSnapshot() ?? false
            let audio = native.systemAudio?.snapshot ?? [:], offEnd = cachedPlayout(native)
            let desiredOff = audio["playoutEnabledRequested"] as? Bool == false
            let appliedOff = !model.snapshot.playoutOn && audio["outputAvailable"] as? Bool == false
            let captureClosed = !model.snapshot.microphoneOn && !model.microphoneStarting &&
                audio["inputAvailable"] as? Bool == false && audio["microphoneMuted"] as? Bool == true &&
                LKRTCApplicationCaptureMuted() == 1
            let physicalOff = offFresh && audio["engineRunning"] as? Bool == false &&
                offEnd.callbacks == offBaseline.callbacks
            let safe = desiredOff && appliedOff && captureClosed && physicalOff &&
                audio["stoppedInputPreparationResult"] as? Int == 0
            emit("warmupSoundOff", ["id": id, "joinSeconds": joinedAt - joinStart,
                "intentLatchSeconds": latchedAt - mutation, "joinAfterMutationSeconds": joinedAt - mutation,
                "prewarmActiveAtIntentLatch": overlapObserved, "operationAtLatch": activeAtLatch,
                "desiredOff": desiredOff, "appliedOff": appliedOff, "captureClosed": captureClosed,
                "physicalOutputOff": physicalOff, "offWindowSeconds": now - offStart,
                "physicalCallbackDelta": offEnd.callbacks - offBaseline.callbacks, "physical": audio,
                "safetyChecksPassed": safe, "nativeOverlapProven": false,
                "requiresRetainedSDKLogReview": true, "requiresHeldSubscriptionRTPReview": true])
            acceptance = acceptance && safe
            guard safe else { throw Failure("Sound off during warmup did not remain applied after join") }
            let decodedBefore = native.mediaSnapshot.audio, videoBefore = native.mediaSnapshot.render["advancingFrames"] as? Int ?? 0
            let restoreAt = now
            model.togglePlayout(); await model.waitForMediaActionsForTesting()
            let restoreCommandEnd = now
            try await wait {
                let decoded = native.mediaSnapshot.audio, playout = self.cachedPlayout(native), video = native.mediaSnapshot.render
                return model.snapshot.playoutOn && decoded.callbacks > decodedBefore.callbacks &&
                    playout.callbacks > offEnd.callbacks &&
                    decoded.lastNonSilentUptime.map { $0 >= restoreAt && self.now - $0 < 0.2 } == true &&
                    playout.lastNonSilentUptime.map { $0 >= restoreAt && self.now - $0 < 0.2 } == true &&
                    (video["advancingFrames"] as? Int ?? 0) > videoBefore &&
                    (video["lastFrameUptime"] as? Double).map { $0 >= restoreAt && self.now - $0 < 0.2 } == true
            }
            let restoredAt = now
            let captureStillClosed = !model.snapshot.microphoneOn && LKRTCApplicationCaptureMuted() == 1
            acceptance = acceptance && captureStillClosed
            emit("warmupSoundRestored", ["id": id, "commandSeconds": restoreCommandEnd - restoreAt,
                "observedReadyUpperSeconds": restoredAt - restoreAt,
                "captureClosed": captureStillClosed, "physical": await native.evidence()])
            guard await cleanup(), captureStillClosed else { throw Failure("Sound warmup scenario cleanup/privacy failed") }
        } catch {
            _ = await model.leave(); _ = try? await joining.value
            throw error
        }
    }

    private func staleIntentScenario(_ scenario: String, model: NativeDesktopMeetingModel,
                                     native: NativeGuestEngine, peer: NativeStartupReceiverProxy) async throws {
        // A final Off state alone cannot prove that native preparation overlapped the action.
        // The retained SDK log must order its caller-preparation marker before MIC_FAULT mutation.
        acceptance = false
        guard ["mute-during-prepare", "leave-during-prepare"].contains(scenario) else {
            emit("faultCaseSkipped", ["scenario": scenario, "reason": "Only actual-model mute/Leave are supported; no direct ADM confinement bypass"])
            guard await cleanup() else { throw Failure("Skipped fault cleanup was not confirmed") }; return
        }
        let usesCoreAudio = native.systemAudio?.backend.usesAudioEngine == false
        let availabilityCall = usesCoreAudio ? "coreaudio-availability" : "set-engine-availability"
        let id = UUID().uuidString, actionStart = now
        let remoteBefore = peer.mediaSnapshot.audio
        var duplexHoldConfigured = false
        var observedDuplex: [String: Any] = [:]
        var duplexAtMutation: [String: Any] = [:]
        #if ROCK_COREAUDIO_DUPLEX_R6
        func duplexHoldReady(_ value: [String: Any]) -> Bool {
            (value["phase"] as? NSNumber)?.uint32Value == 8 &&
                value["prepared"] as? Bool == true && value["holdActive"] as? Bool == true &&
                value["outputRunning"] as? Bool == true && value["captureCommitted"] as? Bool == false
        }
        if usesCoreAudio, native.systemAudio?.duplexStartupEvidenceForTesting["enabled"] as? Bool == true {
            // Only the control executor waits. Input/output have been verified,
            // playback is running, and microphone publication remains gated.
            native.systemAudio?.setDuplexHoldForTesting(phase: 8, milliseconds: 1000)
            duplexHoldConfigured = true
        }
        defer {
            if duplexHoldConfigured { native.systemAudio?.setDuplexHoldForTesting(phase: 0, milliseconds: 0) }
        }
        #endif
        beginWindow("fault", native); native.systemAudio?.setPrivateInputMeterEnabled(true)
        emit("faultEnableBegin", ["id": id, "scenario": scenario, "captureState": String(LKRTCApplicationCaptureState()),
            "duplexReadyHoldConfigured": duplexHoldConfigured, "faultRunIsStartupTimingProof": false,
            "duplexHoldCoverage": "controlled-late-completion; not natural HAL-work overlap"])
        model.toggleMicrophone()
        var operation: [String: Any] = [:]
        try await wait(seconds: 5) {
            let active = native.systemAudio?.snapshot["audioActiveOperation"] as? [String: Any] ?? [:]
            guard active["name"] as? String == "microphone-activate", active["stage"] as? String == "native-call",
                  active["nativeCall"] as? String == availabilityCall,
                  (active["nativeStartedAt"] as? Double ?? 0) >= actionStart else { return false }
            #if ROCK_COREAUDIO_DUPLEX_R6
            if duplexHoldConfigured {
                let duplex = native.systemAudio?.duplexStartupEvidenceForTesting ?? [:]
                guard duplexHoldReady(duplex) else { return false }
                observedDuplex = duplex
            }
            #endif
            operation = active; return true
        }
        let observedAt = now
        emit("faultAvailabilityObserved", ["id": id, "operation": operation,
            "duplexReadyHoldConfigured": duplexHoldConfigured, "duplex": observedDuplex])
        // Cached native startup is about 150–200 ms. Mutate while it is in flight.
        let mutationDelay = usesCoreAudio ? 0 : (scenario == "leave-during-prepare" ? 80 : 40)
        try await Task.sleep(for: .milliseconds(mutationDelay))
        let active = native.systemAudio?.snapshot["audioActiveOperation"] as? [String: Any] ?? [:]
        let stillActive = active["id"] as? Int == operation["id"] as? Int &&
            active["stage"] as? String == "native-call" && active["nativeCall"] as? String == availabilityCall
        #if ROCK_COREAUDIO_DUPLEX_R6
        if duplexHoldConfigured {
            duplexAtMutation = native.systemAudio?.duplexStartupEvidenceForTesting ?? [:]
            let owner = (observedDuplex["ownerGeneration"] as? NSNumber)?.uint64Value ?? 0
            let physical = (observedDuplex["physicalGeneration"] as? NSNumber)?.uint64Value ?? 0
            let serial = (observedDuplex["activePrepareSerial"] as? NSNumber)?.uint64Value ?? 0
            let callID = (operation["nativeCallID"] as? NSNumber)?.uint64Value ?? 0
            guard stillActive, duplexHoldReady(duplexAtMutation), LKRTCApplicationCaptureMuted() == 1,
                  owner > 0, physical > 0, serial > 0, callID > 0,
                  (duplexAtMutation["ownerGeneration"] as? NSNumber)?.uint64Value == owner,
                  (duplexAtMutation["physicalGeneration"] as? NSNumber)?.uint64Value == physical,
                  (duplexAtMutation["activePrepareSerial"] as? NSNumber)?.uint64Value == serial,
                  (active["nativeCallID"] as? NSNumber)?.uint64Value == callID,
                  active["nativeStartedAt"] as? Double == operation["nativeStartedAt"] as? Double else {
                emit("faultOverlapNotProven", ["id": id, "operation": active, "duplex": duplexAtMutation])
                throw Failure("R6 preparation hold was no longer active with running output and gated capture before mutation")
            }
        }
        #endif
        let mutationAt = now, beforeState = LKRTCApplicationCaptureState()
        LKRTCLogEx(.info, "MIC_FAULT mutation id=\(id) scenario=\(scenario) uptime=\(mutationAt) captureState=\(beforeState)")
        var samplePrivacy = false, gateOpened = false, modelReopened = false, privacySamples = 0
        let privacyWatch = Task { @MainActor in
            while !Task.isCancelled {
                if samplePrivacy {
                    privacySamples += 1; gateOpened = gateOpened || LKRTCApplicationCaptureMuted() != 1
                    modelReopened = modelReopened || model.snapshot.microphoneOn
                }
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
        }
        defer { privacyWatch.cancel() }
        var localLeaveConfirmed = true, immediateGateMuted = false
        var privacyLatchBefore = now, privacyLatchAfter = now
        if scenario == "leave-during-prepare" {
            let leaving = Task { @MainActor in
                privacyLatchBefore = self.now
                return await model.leave()
            }
            try await wait(seconds: 1) { model.snapshot.phase == .leaving || model.snapshot.phase == .left }
            privacyLatchAfter = now
            samplePrivacy = true
            immediateGateMuted = LKRTCApplicationCaptureMuted() == 1
            emit("faultPrivacyBarrier", ["id": id, "captureState": String(LKRTCApplicationCaptureState()), "gateMuted": LKRTCApplicationCaptureMuted()])
            #if ROCK_COREAUDIO_DUPLEX_R6
            // Current hold retains its captured deadline. Clear only future holds.
            if duplexHoldConfigured { native.systemAudio?.setDuplexHoldForTesting(phase: 0, milliseconds: 0) }
            #endif
            localLeaveConfirmed = await leaving.value
        } else {
            privacyLatchBefore = now
            model.toggleMicrophone(); privacyLatchAfter = now
            samplePrivacy = true; immediateGateMuted = LKRTCApplicationCaptureMuted() == 1
            emit("faultPrivacyBarrier", ["id": id, "captureState": String(LKRTCApplicationCaptureState()), "gateMuted": LKRTCApplicationCaptureMuted()])
            #if ROCK_COREAUDIO_DUPLEX_R6
            if duplexHoldConfigured { native.systemAudio?.setDuplexHoldForTesting(phase: 0, milliseconds: 0) }
            #endif
        }
        await model.waitForMediaActionsForTesting()
        try await Task.sleep(for: .seconds(2)) // Catch late completion after the control tail drains.
        privacyWatch.cancel(); await privacyWatch.value
        let continuity = endWindow("fault", native)
        monitor?.cancel(); await monitor?.value; monitor = nil
        let senders = native.audioSendersForTesting
        let senderState: [[String: Any]] = senders.map { ["trackEnabled": $0.trackEnabled,
            "encodingActive": $0.encodingActive] }
        // Audio mute suppresses the track; RTP encodings can remain active for comfort noise.
        let suppressed = senders.allSatisfy { !$0.trackEnabled }
        let captureState = LKRTCApplicationCaptureState(), gateMuted = LKRTCApplicationCaptureMuted() == 1
        let remote = peer.mediaSnapshot.audio.since(remoteBefore)
        let physical = await native.evidence() // All critical windows and sampling have ended.
        let audio = physical["physicalAudio"] as? [String: Any] ?? [:]
        // Muting an explicitly requested microphone keeps its graph available, as in the
        // existing path. Leave additionally withdraws availability and confirms hardware stop.
        let requiresInputOff = !usesCoreAudio || scenario == "leave-during-prepare"
        let nativeMuted = audio["microphoneMuted"] as? Bool == true &&
            (requiresInputOff ? audio["inputAvailable"] as? Bool == false : audio["inputAvailable"] as? Bool != nil)
        let completedOperation = (audio["audioOperations"] as? [[String: Any]] ?? []).first { $0["id"] as? Int == operation["id"] as? Int }
        let completedCalls = completedOperation?["nativeCalls"] as? [[String: Any]] ?? []
        let overlapProven = completedCalls.contains { call in
            guard call["name"] as? String == availabilityCall, let start = call["startedAt"] as? Double,
                  let seconds = call["seconds"] as? Double, start.isFinite, seconds.isFinite, seconds > 0 else { return false }
            if duplexHoldConfigured {
                guard let callID = (operation["nativeCallID"] as? NSNumber)?.uint64Value, callID > 0,
                      (call["nativeCallID"] as? NSNumber)?.uint64Value == callID,
                      operation["nativeStartedAt"] as? Double == start else { return false }
            }
            return start < privacyLatchBefore && start + seconds > privacyLatchAfter
        }
        var nativeLeaveRevokedBeforePrepareReturned = true
        #if ROCK_COREAUDIO_DUPLEX_R6
        if duplexHoldConfigured && scenario == "leave-during-prepare" {
            let owner = (duplexAtMutation["ownerGeneration"] as? NSNumber)?.uint64Value
            let terminal = (audio["duplexIntentLatches"] as? [[String: Any]] ?? []).first { latch in
                guard let owner, owner > 0, latch["source"] as? String == "termination", latch["accepted"] as? Bool == true,
                      (latch["ownerGeneration"] as? NSNumber)?.uint64Value == owner,
                      let before = latch["beforeUptime"] as? Double, let after = latch["afterUptime"] as? Double,
                      let flags = (latch["flags"] as? NSNumber)?.uint32Value else { return false }
                return before.isFinite && after.isFinite && before <= after &&
                    before >= privacyLatchBefore && after <= privacyLatchAfter && flags & 8 != 0 && flags & 4 == 0
            }
            nativeLeaveRevokedBeforePrepareReturned = terminal != nil && completedCalls.contains { call in
                guard let after = terminal?["afterUptime"] as? Double,
                      call["name"] as? String == availabilityCall,
                      (call["nativeCallID"] as? NSNumber)?.uint64Value == (operation["nativeCallID"] as? NSNumber)?.uint64Value,
                      let start = call["startedAt"] as? Double, let seconds = call["seconds"] as? Double else { return false }
                return start.isFinite && seconds.isFinite && seconds > 0 && after < start + seconds
            }
        }
        #endif
        let safety = nativeLeaveRevokedBeforePrepareReturned && !model.snapshot.microphoneOn && !model.microphoneStarting && privacySamples > 0 && immediateGateMuted && gateMuted && !gateOpened && !modelReopened &&
            captureState != beforeState && suppressed && (scenario == "leave-during-prepare" || !senders.isEmpty) && nativeMuted && localLeaveConfirmed
        if usesCoreAudio {
            acceptance = safety && overlapProven && (scenario == "leave-during-prepare" || continuity["passed"] as? Bool == true)
        }
        emit("faultCaseResult", ["id": id, "scenario": scenario, "availabilityActiveAtMutation": stillActive,
            "duplexReadyHoldConfigured": duplexHoldConfigured, "duplexAtObservation": observedDuplex,
            "duplexAtMutation": duplexAtMutation,
            "faultRunIsStartupTimingProof": false,
            "duplexHoldCoverage": "controlled-late-completion; not natural HAL-work overlap",
            "delayAfterObservationSeconds": mutationAt - observedAt, "captureStateBeforeMutation": String(beforeState), "captureStateAfterDrain": String(captureState),
            "immediateGateMuted": immediateGateMuted, "gateMutedAfterDrain": gateMuted, "gateOpenedAfterPrivacyBarrier": gateOpened, "modelReopenedAfterPrivacyBarrier": modelReopened,
            "privacySamples": privacySamples, "modelMicrophoneOn": model.snapshot.microphoneOn, "modelMicrophoneStarting": model.microphoneStarting,
            "senderState": senderState, "nativePrivacyStateSafe": nativeMuted, "nativeInputAvailable": audio["inputAvailable"] as Any? ?? NSNull(), "localLeaveConfirmed": localLeaveConfirmed,
            "safetyChecksPassed": safety, "nativeOverlapProven": usesCoreAudio && overlapProven, "requiresRetainedSDKLogReview": !usesCoreAudio,
            "nativeLeaveRevokedBeforePrepareReturned": nativeLeaveRevokedBeforePrepareReturned,
            "privacyLatchBefore": privacyLatchBefore, "privacyLatchAfter": privacyLatchAfter,
            "completedAvailabilityOperation": completedOperation as Any? ?? NSNull(), "inputOffRequired": requiresInputOff,
            "remotePCM": ["samples": remote.samples, "energy": remote.energy, "nonSilentCallbacks": remote.nonSilentCallbacks],
            "remotePCMIsPublicationProof": false, "speechClassified": false, "incomingContinuityExpected": scenario != "leave-during-prepare",
            "incoming": continuity, "physical": physical])
        guard await cleanup() else { throw Failure("Fault scenario cleanup was not confirmed") }
    }
    private func cleanup() async -> Bool {
        if let cleanupTask { return await cleanupTask.value }
        let task = Task { @MainActor in
            #if ROCK_COREAUDIO_DUPLEX_R6
            if self.rawStartSupersessionEnabled {
                self.rawStartSupersessionTask?.cancel(); await self.rawStartSupersessionTask?.value; self.rawStartSupersessionTask = nil
                self.finishRawStartSupersessionProbe(self.adapter?.currentNativeEngine)
            }
            #endif
            self.startupStageTask?.cancel(); await self.startupStageTask?.value; self.startupStageTask = nil; self.startupTimeline = nil
            self.monitor?.cancel(); await self.monitor?.value; self.monitor = nil; self.windows.removeAll()
            let local = await self.model?.leave() ?? true, remote = await self.peer?.leave() ?? true
            self.window?.contentView = nil; self.window?.orderOut(nil); self.window = nil
            self.model = nil; self.adapter = nil; self.peer = nil; self.stopLogger()
            self.emit("meetingStopped", ["app": local, "peer": remote])
            return local && remote
        }
        cleanupTask = task; let result = await task.value; cleanupTask = nil; return result
    }
    private struct Continuity {
        let baseline: GuestAudioSnapshot, start: Double, endAgeLimit: Double
        var latest: GuestAudioSnapshot, previous: Double?, previousNonSilent: Double?
        var nonSilentGap = 0.0, nonSilentAge = 0.0
        var gap = 0.0, gapStart = 0.0, gapEnd = 0.0, age = 0.0, ageStart = 0.0, ageEnd = 0.0
        init(_ value: GuestAudioSnapshot, at time: Double, endAgeLimit: Double) {
            baseline = value; latest = value; start = time; self.endAgeLimit = endAgeLimit
            previous = value.lastCallbackUptime; previousNonSilent = value.lastNonSilentUptime
        }
        mutating func sample(_ value: GuestAudioSnapshot, at time: Double) {
            latest = value
            if let callback = value.lastCallbackUptime, callback > (previous ?? -.infinity) {
                let earlier = previous ?? start
                if callback - earlier > gap { gap = callback - earlier; gapStart = earlier; gapEnd = callback }
                previous = callback
            }
            if let nonSilent = value.lastNonSilentUptime, nonSilent > (previousNonSilent ?? -.infinity) {
                nonSilentGap = max(nonSilentGap, nonSilent - (previousNonSilent ?? start))
                previousNonSilent = nonSilent
            }
            nonSilentAge = max(nonSilentAge, time - (value.lastNonSilentUptime ?? start))
            let callback = value.lastCallbackUptime ?? start
            if time - callback > age { age = time - callback; ageStart = callback; ageEnd = time }
        }
        func result(at time: Double) -> [String: Any] {
            let fresh = latest.since(baseline), endAge = time - (latest.lastCallbackUptime ?? start)
            let endNonSilentAge = time - (latest.lastNonSilentUptime ?? start)
            return ["start": start, "end": time, "callbacks": fresh.callbacks, "nonSilentCallbacks": fresh.nonSilentCallbacks,
                "samples": fresh.samples, "energy": fresh.energy, "rms": fresh.rms,
                "maximumObservedCallbackGapUpperSeconds": gap, "maximumGapStart": gapStart, "maximumGapEnd": gapEnd,
                "maximumCallbackAgeSeconds": age, "maximumAgeStart": ageStart, "maximumAgeEnd": ageEnd,
                "maximumNonSilentGapUpperSeconds": nonSilentGap, "maximumNonSilentAgeSeconds": nonSilentAge,
                "endNonSilentAgeSeconds": endNonSilentAge, "continuousNonSilentFixture": true,
                "endCallbackAgeSeconds": endAge, "maximumAllowedGapSeconds": 0.35, "maximumAllowedEndAgeSeconds": endAgeLimit,
                "passed": fresh.callbacks > 0 && fresh.energy > 0 && fresh.lastNonSilentUptime.map { $0 >= start } == true &&
                    gap < 0.35 && age < 0.35 && endAge < endAgeLimit &&
                    nonSilentGap < 0.35 && nonSilentAge < 0.35 && endNonSilentAge < endAgeLimit]
        }
    }
    private final class ReceiveWindow {
        var decoded: Continuity, playout: Continuity
        var mainMaximum = 0.0, mainStart = 0.0, mainEnd = 0.0
        init(decoded: GuestAudioSnapshot, playout: GuestAudioSnapshot, at time: Double) {
            self.decoded = .init(decoded, at: time, endAgeLimit: 0.1); self.playout = .init(playout, at: time, endAgeLimit: 0.2)
        }
        func sample(decoded: GuestAudioSnapshot, playout: GuestAudioSnapshot, at time: Double) {
            self.decoded.sample(decoded, at: time); self.playout.sample(playout, at: time)
        }
        func sampleMain(from start: Double, to end: Double) {
            if end - start > mainMaximum { mainMaximum = end - start; mainStart = start; mainEnd = end }
        }
        func result(at time: Double) -> [String: Any] {
            let decoded = self.decoded.result(at: time), playout = self.playout.result(at: time)
            return ["decoded": decoded, "physicalPlayout": playout, "mainActorMaximumSeconds": mainMaximum,
                "mainActorGapStart": mainStart, "mainActorGapEnd": mainEnd,
                "passed": decoded["passed"] as? Bool == true && playout["passed"] as? Bool == true && mainMaximum < 0.35]
        }
    }
    private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
#endif
