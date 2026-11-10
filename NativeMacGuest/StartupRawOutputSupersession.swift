#if DEBUG
import Foundation
import CoreFoundation

// Pure evidence checks for the opt-in initial raw-start diagnostic. These
// snapshots grant no authority and never start, stop or wait on native IO.
enum StartupRawOutputSupersession {
    struct Window {
        let owner: UInt64, serial: UInt64, intent: UInt64, authority: UInt64, outputAuthority: UInt64
        let operation: UInt64, call: UInt64
        let nativeStarted: Double, rawStarted: Double, deadline: Double, observed: Double
        func same(as other: Window) -> Bool {
            owner == other.owner && serial == other.serial && authority == other.authority &&
            outputAuthority == other.outputAuthority && operation == other.operation && call == other.call &&
            nativeStarted == other.nativeStarted && rawStarted == other.rawStarted && deadline == other.deadline
        }
        var evidence: [String: Any] {
            ["ownerGeneration": owner, "prepareSerial": serial, "oldIntent": intent, "oldAuthority": authority,
             "outputAuthority": outputAuthority, "audioOperationID": operation, "nativeCallID": call,
             "nativeStartedAt": nativeStarted, "rawStartMarkerUptime": rawStarted, "operationDeadlineUptime": deadline, "observedAt": observed]
        }
    }
    struct Attempt {
        let window: Window, before: Double, after: Double
        let latch: [String: Any]
        var evidence: [String: Any] { ["window": window.evidence, "actionBefore": before, "actionAfter": after, "latch": latch] }
    }
    struct Result {
        let exercised: Bool, reason: String
        let evidence: [String: Any]
    }
    static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return UInt64(number.stringValue)
    }
    static func time(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let value = number.doubleValue
        return value.isFinite && value > 0 ? value : nil
    }
    static func window(duplex: [String: Any], operation: [String: Any], at observed: Double) -> Window? {
        guard observed.isFinite, duplex["enabled"] as? Bool == true,
              duplex["presealOutputPrimingSupported"] as? Bool == true,
              duplex["transportPinned"] as? Bool == true, duplex["transportQuarantined"] as? Bool == false,
              unsigned(duplex["phase"]) == 13, unsigned(duplex["physicalGeneration"]) == 0,
              unsigned(duplex["outputCreateCount"]) == 1, unsigned(duplex["outputStartCount"]) == 0,
              unsigned(duplex["outputBindCount"]) == 0, unsigned(duplex["outputStartReturnNanos"]) == 0,
              unsigned(duplex["inputCreateCount"]) == 0, unsigned(duplex["observedRouteEvents"]) == 0,
              duplex["outputDataReady"] as? Bool == false, duplex["captureCommitted"] as? Bool == false, duplex["prepared"] as? Bool == false,
              let owner = unsigned(duplex["ownerGeneration"]), owner > 0,
              let serial = unsigned(duplex["activePrepareSerial"]), serial > 0,
              let word = unsigned(duplex["authority"]), word & 31 == 6, word >> 36 > 0,
              let output = unsigned(duplex["outputAuthority"]), output & (1 << 63) == 0, output & 31 == 18, // Raw + Sound
              let phases = duplex["phaseFirstNanos"] as? [Any], phases.count > 13,
              let marker = unsigned(phases[13]), marker > 0,
              operation["stage"] as? String == "native-call", operation["nativeCall"] as? String == "coreaudio-availability",
              let id = unsigned(operation["id"]), id > 0, let call = unsigned(operation["nativeCallID"]), call > 0,
              let started = time(operation["nativeStartedAt"]), started <= Double(marker) * 1e-9,
              let deadline = time(operation["deadlineAt"]), observed < deadline,
              Double(marker) * 1e-9 <= observed else { return nil }
        return Window(owner: owner, serial: serial, intent: word >> 36, authority: word, outputAuthority: output,
            operation: id, call: call, nativeStarted: started, rawStarted: Double(marker) * 1e-9, deadline: deadline, observed: observed)
    }
    static func attempt(window: Window, before: Double, after: Double, latches: [[String: Any]]) -> Attempt {
        let latch = latches.last { unsigned($0["ownerGeneration"]) == window.owner && $0["source"] as? String == "track" &&
            unsigned($0["sequence"]) == window.intent + 1 && $0["accepted"] as? Bool == true } ?? [:]
        return Attempt(window: window, before: before, after: after, latch: latch)
    }
    private static func captureAuthorityChange(from old: UInt64, to current: UInt64, core: [String: Any]) -> String? {
        if old == current { return "unchanged" }
        // Only SetCaptureDemand(true) may change this output-only observation:
        // Closed -> Open advances the shared capture epoch exactly once.
        let epochMask: UInt64 = (1 << 28) - 1
        let oldEpoch = (old >> 8) & epochMask, currentEpoch = (current >> 8) & epochMask
        guard old & 255 == 134, current & 255 == 6, old >> 36 == current >> 36,
              oldEpoch < epochMask, currentEpoch == oldEpoch + 1,
              core["recordingRequested"] as? Bool == true, core["inputAvailable"] as? Bool == false,
              core["recording"] as? Bool == false else { return nil }
        return "singleNativeCaptureDemandOpened"
    }
    static func verify(_ attempt: Attempt?, duplex: [String: Any], core: [String: Any], snapshot: [String: Any]) -> Result {
        func reject(_ reason: String) -> Result { Result(exercised: false, reason: reason, evidence: attempt?.evidence ?? [:]) }
        guard let attempt else { return reject("initialRawStartWindowNotObserved") }
        let w = attempt.window, latch = attempt.latch
        guard unsigned(latch["ownerGeneration"]) == w.owner, latch["source"] as? String == "track",
              unsigned(latch["sequence"]) == w.intent + 1, latch["accepted"] as? Bool == true,
              let latchBefore = time(latch["beforeUptime"]), let latchAfter = time(latch["afterUptime"]),
              let latchWord = unsigned(latch["authority"]), latchWord >> 36 == w.intent + 1,
              unsigned(latch["flags"]) == w.authority & 31, latchWord & ((1 << 36) - 1) == w.authority & ((1 << 36) - 1),
              let returnedNanos = unsigned(duplex["outputStartReturnNanos"]), returnedNanos > 0 else { return reject("acceptedSameFlagsLatchNotProven") }
        let returned = Double(returnedNanos) * 1e-9
        guard w.nativeStarted <= w.rawStarted, w.rawStarted <= w.observed, w.observed <= attempt.before,
              attempt.before <= latchBefore, latchBefore <= latchAfter, latchAfter <= attempt.after,
              attempt.after < returned else { return reject("latchMissedRawStartMarkerToReturnWindow") }
        let receipts = snapshot["duplexPreparationReceipts"] as? [[String: Any]] ?? []
        guard let old = receipts.first(where: { unsigned($0["ownerGeneration"]) == w.owner && unsigned($0["nativeCallID"]) == w.call &&
            unsigned($0["audioOperationID"]) == w.operation && unsigned($0["nativePrepareSerial"]) == w.serial }),
              unsigned(old["expectedIntent"]) == w.intent, old["status"] as? Int == -21,
              old["abortReason"] as? String == "intentSuperseded", old["consumptionDecision"] as? String == "retryLatest",
              unsigned(old["consumedIntent"]) == w.intent + 1, unsigned(old["observedAuthority"]) == latchWord,
              time(old["nativeStartedAt"]) == w.nativeStarted, let oldEnd = time(old["nativeFinishedAt"]),
              returned <= oldEnd, let deadline = time(old["nativeDeadlineUptime"]), oldEnd < min(deadline, w.deadline),
              let accepted = receipts.first(where: { unsigned($0["ownerGeneration"]) == w.owner && unsigned($0["audioOperationID"]) == w.operation &&
                  unsigned($0["expectedIntent"]) == w.intent + 1 && $0["status"] as? Int == 0 && $0["consumptionDecision"] as? String == "accept" }),
              let acceptedCall = unsigned(accepted["nativeCallID"]), acceptedCall > w.call,
              let acceptedSerial = unsigned(accepted["nativePrepareSerial"]), acceptedSerial > w.serial,
              unsigned(accepted["observedAuthority"]) == latchWord, unsigned(accepted["consumedIntent"]) == w.intent + 1,
              let acceptedStart = time(accepted["nativeStartedAt"]), let acceptedEnd = time(accepted["nativeFinishedAt"]),
              oldEnd <= acceptedStart, acceptedStart <= acceptedEnd, acceptedEnd < min(deadline, w.deadline),
              time(accepted["nativeDeadlineUptime"]) == deadline else { return reject("correlatedStaleThenAcceptedReceiptsNotProven") }
        let operations = snapshot["audioOperations"] as? [[String: Any]] ?? []
        guard let operation = operations.first(where: { unsigned($0["id"]) == w.operation }), operation["succeeded"] as? Bool == true,
              time(operation["deadlineAt"]) == w.deadline,
              operation["callerTimedOut"] as? Bool == false,
              let calls = operation["nativeCalls"] as? [[String: Any]],
              calls.contains(where: { unsigned($0["nativeCallID"]) == w.call && time($0["startedAt"]) == w.nativeStarted }),
              calls.contains(where: { unsigned($0["nativeCallID"]) == acceptedCall && time($0["startedAt"]) == acceptedStart }),
              unsigned(duplex["ownerGeneration"]) == w.owner, let finalAuthority = unsigned(duplex["authority"]),
              let authorityChange = captureAuthorityChange(from: latchWord, to: finalAuthority, core: core),
              let output = unsigned(duplex["outputAuthority"]), output & 31 == 21, // Bound + Active + Sound
              output & ~UInt64(31) == w.outputAuthority & ~UInt64(31),
              unsigned(duplex["outputCreateCount"]) == 1, unsigned(duplex["outputStartCount"]) == 1,
              unsigned(duplex["outputBindCount"]) == 1, (unsigned(duplex["outputCallbacks"]) ?? 0) > 0,
              unsigned(duplex["observedRouteEvents"]) == 0, unsigned(duplex["inputCreateCount"]) == 0,
              unsigned(duplex["inputStartCount"]) == 0, unsigned(duplex["inputCallbacks"]) == 0,
              duplex["inputRunning"] as? Bool == false, duplex["prepared"] as? Bool == false,
              unsigned(duplex["physicalGeneration"]) == 0, duplex["outputDataReady"] as? Bool == true,
              duplex["outputRunning"] as? Bool == true, duplex["captureCommitted"] as? Bool == false,
              duplex["transportQuarantined"] as? Bool == false,
              core["cleanupUnconfirmed"] as? Bool == false, core["captureMuted"] as? Bool == true, let diagnostic = core["nativeDiagnostics"] as? [String: Any],
              diagnostic["firstError"] as? Int == 0, unsigned(diagnostic["unsafeFailureMask"]) == 0,
              unsigned(diagnostic["observedRouteGeneration"]) == 0, (duplex["routeEvents"] as? [Any])?.isEmpty == true,
              diagnostic["retirementRequested"] as? Bool == false,
              unsigned(diagnostic["inputRetirementRequired"]) == 0, unsigned(diagnostic["outputRetirementRequired"]) == 0 else { return reject("sameOwnedOutputGenerationProgressNotProven") }
        return Result(exercised: true, reason: "controlledInitialRawStartSupersession", evidence: attempt.evidence.merging(
            ["rawStartReturnUptime": returned, "oldReceipt": old, "acceptedReceipt": accepted,
             "finalCaptureAuthority": finalAuthority, "finalCaptureAuthorityChange": authorityChange,
             "outputCreateCount": 1, "outputStartCount": 1, "outputBindCount": 1,
             "convertedOutputCallbacks": unsigned(duplex["outputCallbacks"]) ?? 0]) { _, new in new })
    }
}
#endif
