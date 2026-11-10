import Foundation

@main struct RawOutputSupersessionTests {
    static func main() {
        typealias Probe = StartupRawOutputSupersession
        let old: UInt64 = (9 << 36) | 134, new: UInt64 = (10 << 36) | 134
        var phases = [UInt64](repeating: 0, count: 15); phases[13] = 10_020_000_000
        let active: [String: Any] = ["id": 4, "stage": "native-call", "nativeCall": "coreaudio-availability", "nativeCallID": 12, "nativeStartedAt": 10.0, "deadlineAt": 11.0]
        var duplex: [String: Any] = ["enabled": true, "presealOutputPrimingSupported": true,
            "transportPinned": true, "transportQuarantined": false, "phase": 13, "physicalGeneration": 0,
            "outputCreateCount": 1, "outputStartCount": 0, "outputBindCount": 0, "outputStartReturnNanos": 0,
            "inputCreateCount": 0, "inputStartCount": 0, "inputCallbacks": 0, "inputRunning": false,
            "observedRouteEvents": 0, "routeEvents": [], "outputDataReady": false,
            "captureCommitted": false, "prepared": false, "ownerGeneration": 7, "activePrepareSerial": 3,
            "authority": old, "outputAuthority": 210, "phaseFirstNanos": phases]
        guard let window = Probe.window(duplex: duplex, operation: active, at: 10.03) else { fatalError("valid window rejected") }
        var missed = duplex; missed["outputStartReturnNanos"] = UInt64(10_040_000_000)
        precondition(Probe.window(duplex: missed, operation: active, at: 10.05) == nil)
        var changedOwner = duplex; changedOwner["ownerGeneration"] = 8
        precondition(Probe.window(duplex: changedOwner, operation: active, at: 10.03)?.same(as: window) == false)
        var bound = duplex; bound["outputAuthority"] = 213
        precondition(Probe.window(duplex: bound, operation: active, at: 10.03) == nil)
        let latch: [String: Any] = ["ownerGeneration": 7, "source": "track", "sequence": 10, "authority": new,
            "flags": 6, "accepted": true, "beforeUptime": 10.041, "afterUptime": 10.042]
        let attempt = Probe.attempt(window: window, before: 10.04, after: 10.043, latches: [latch])
        let before: [String: Any] = ["ownerGeneration": 7, "physicalGeneration": 0, "nativeCallID": 12, "audioOperationID": 4,
            "nativePrepareSerial": 3, "expectedIntent": 9, "status": -21, "abortReason": "intentSuperseded",
            "consumptionDecision": "retryLatest", "consumedIntent": 10, "observedAuthority": new,
            "nativeStartedAt": 10.0, "nativeFinishedAt": 10.07, "nativeDeadlineUptime": 11.0]
        let after: [String: Any] = ["ownerGeneration": 7, "audioOperationID": 4, "expectedIntent": 10, "status": 0,
            "consumptionDecision": "accept", "consumedIntent": 10, "observedAuthority": new, "nativeCallID": 13, "nativePrepareSerial": 4, "nativeStartedAt": 10.08,
            "nativeFinishedAt": 10.1, "nativeDeadlineUptime": 11.0]
        let operation: [String: Any] = ["id": 4, "succeeded": true, "callerTimedOut": false, "deadlineAt": 11.0,
            "nativeCalls": [["nativeCallID": 12, "startedAt": 10.0], ["nativeCallID": 13, "startedAt": 10.08]]]
        var snapshot: [String: Any] = ["duplexPreparationReceipts": [before, after], "audioOperations": [operation]]
        duplex["authority"] = new; duplex["outputStartCount"] = 1; duplex["outputBindCount"] = 1
        duplex["outputStartReturnNanos"] = UInt64(10_060_000_000); duplex["outputCallbacks"] = 2
        duplex["outputDataReady"] = true; duplex["outputRunning"] = true
        duplex["outputAuthority"] = 213
        let core: [String: Any] = ["cleanupUnconfirmed": false, "captureMuted": true,
            "nativeDiagnostics": ["firstError": 0, "unsafeFailureMask": 0, "observedRouteGeneration": 0, "retirementRequested": false,
                "inputRetirementRequired": 0, "outputRetirementRequired": 0]]
        precondition(Probe.verify(attempt, duplex: duplex, core: core, snapshot: snapshot).exercised)
        precondition(!Probe.verify(nil, duplex: duplex, core: core, snapshot: snapshot).exercised)
        missed = duplex; missed["outputStartReturnNanos"] = UInt64(10_040_000_000)
        precondition(!Probe.verify(attempt, duplex: missed, core: core, snapshot: snapshot).exercised)
        missed = duplex; missed["outputStartCount"] = 2
        precondition(!Probe.verify(attempt, duplex: missed, core: core, snapshot: snapshot).exercised)
        missed = duplex; missed["outputCallbacks"] = 0
        precondition(!Probe.verify(attempt, duplex: missed, core: core, snapshot: snapshot).exercised)
        var changed = after; changed["nativeDeadlineUptime"] = 12.0
        snapshot["duplexPreparationReceipts"] = [before, changed]
        precondition(!Probe.verify(attempt, duplex: duplex, core: core, snapshot: snapshot).exercised)
        changed = before; changed["status"] = 0; snapshot["duplexPreparationReceipts"] = [changed, after]
        precondition(!Probe.verify(attempt, duplex: duplex, core: core, snapshot: snapshot).exercised)
        changed = before; changed["nativeCallID"] = 14; snapshot["duplexPreparationReceipts"] = [changed, after]
        precondition(!Probe.verify(attempt, duplex: duplex, core: core, snapshot: snapshot).exercised)
        changed = after; changed["observedAuthority"] = old; snapshot["duplexPreparationReceipts"] = [before, changed]
        precondition(!Probe.verify(attempt, duplex: duplex, core: core, snapshot: snapshot).exercised)
        changed = after; changed["nativePrepareSerial"] = 3; snapshot["duplexPreparationReceipts"] = [before, changed]
        precondition(!Probe.verify(attempt, duplex: duplex, core: core, snapshot: snapshot).exercised)
        snapshot["duplexPreparationReceipts"] = [before, after]
        missed = duplex; missed["outputAuthority"] = 245
        precondition(!Probe.verify(attempt, duplex: missed, core: core, snapshot: snapshot).exercised)
        var earlyDeadline = active; earlyDeadline["deadlineAt"] = 10.09
        var initial = duplex; initial["authority"] = old; initial["outputAuthority"] = 210
        initial["phaseFirstNanos"] = phases; initial["outputStartReturnNanos"] = 0; initial["outputStartCount"] = 0
        initial["outputBindCount"] = 0; initial["outputDataReady"] = false
        let earlyWindow = Probe.window(duplex: initial, operation: earlyDeadline, at: 10.03)!
        let earlyAttempt = Probe.attempt(window: earlyWindow, before: 10.04, after: 10.043, latches: [latch])
        var earlyOperation = operation; earlyOperation["deadlineAt"] = 10.09; snapshot["audioOperations"] = [earlyOperation]
        precondition(!Probe.verify(earlyAttempt, duplex: duplex, core: core, snapshot: snapshot).exercised)
        snapshot["audioOperations"] = [operation]
        var demand = duplex; demand["authority"] = new + 128 // Closed cleared; capture epoch advances once.
        var demandCore = core; demandCore["recordingRequested"] = true; demandCore["inputAvailable"] = false; demandCore["recording"] = false
        let opened = Probe.verify(attempt, duplex: demand, core: demandCore, snapshot: snapshot)
        precondition(opened.exercised && opened.evidence["finalCaptureAuthorityChange"] as? String == "singleNativeCaptureDemandOpened")
        precondition(!Probe.verify(attempt, duplex: demand, core: core, snapshot: snapshot).exercised)
        missed = demand; missed["authority"] = new + 384 // Two epoch advances cannot be this single demand step.
        precondition(!Probe.verify(attempt, duplex: missed, core: demandCore, snapshot: snapshot).exercised)
        missed = demand; missed["authority"] = new + 512 // Closed again: demand ABA.
        precondition(!Probe.verify(attempt, duplex: missed, core: demandCore, snapshot: snapshot).exercised)
        missed = demand; missed["routeEvents"] = [["ready": true]]
        precondition(!Probe.verify(attempt, duplex: missed, core: demandCore, snapshot: snapshot).exercised)
        missed = demand; missed["inputCallbacks"] = 1
        precondition(!Probe.verify(attempt, duplex: missed, core: demandCore, snapshot: snapshot).exercised)
        var failed = core; failed["cleanupUnconfirmed"] = true
        precondition(!Probe.verify(attempt, duplex: duplex, core: failed, snapshot: snapshot).exercised)
        precondition(Probe.unsigned(NSNumber(value: UInt64.max)) == UInt64.max)
        precondition(Probe.unsigned(true) == nil && Probe.unsigned(1.5) == nil)
        print("PASS: controlled raw-start eligibility, exact latch/span/deadline/owner/registration proof; missed windows reject")
        if CommandLine.arguments.count == 2 { replay(CommandLine.arguments[1]) }
    }
    static func replay(_ path: String) {
        typealias Probe = StartupRawOutputSupersession
        var snapshot: [String: Any] = [:], evidence: [String: Any] = [:]
        for line in try! String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
            let prefix = "MICROPHONE_ACTIVATION_EVENT "
            guard line.hasPrefix(prefix), let data = String(line.dropFirst(prefix.count)).data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if value["event"] as? String == "incomingReady" { snapshot = value["physicalAudio"] as? [String: Any] ?? [:] }
            if value["event"] as? String == "controlledRawStartTrackSupersession" { evidence = value["evidence"] as? [String: Any] ?? [:] }
        }
        let w = evidence["window"] as! [String: Any]
        let window = Probe.Window(owner: Probe.unsigned(w["ownerGeneration"])!, serial: Probe.unsigned(w["prepareSerial"])!,
            intent: Probe.unsigned(w["oldIntent"])!, authority: Probe.unsigned(w["oldAuthority"])!, outputAuthority: Probe.unsigned(w["outputAuthority"])!,
            operation: Probe.unsigned(w["audioOperationID"])!, call: Probe.unsigned(w["nativeCallID"])!, nativeStarted: Probe.time(w["nativeStartedAt"])!,
            rawStarted: Probe.time(w["rawStartMarkerUptime"])!, deadline: Probe.time(w["operationDeadlineUptime"])!, observed: Probe.time(w["observedAt"])!)
        let attempt = Probe.Attempt(window: window, before: Probe.time(evidence["actionBefore"])!, after: Probe.time(evidence["actionAfter"])!, latch: evidence["latch"] as! [String: Any])
        let result = Probe.verify(attempt, duplex: snapshot["coreAudioDuplex"] as! [String: Any], core: snapshot["coreAudio"] as! [String: Any], snapshot: snapshot)
        precondition(result.exercised, result.reason)
        print("PASS: retained run replay; \(result.evidence["finalCaptureAuthorityChange"] ?? "missing")")
    }
}
