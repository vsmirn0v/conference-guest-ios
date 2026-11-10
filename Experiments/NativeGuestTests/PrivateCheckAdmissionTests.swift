import Foundation

enum AVMediaType { case audio }
enum AVCaptureDevice {
    enum Status { case authorized }
    static func authorizationStatus(for: AVMediaType) -> Status { .authorized }
}
enum GuestVPIOBuiltInRoute { static var route: [UInt32] = [77, 70]; static func identity() -> [UInt32] { route } }
func LKRTCApplicationCaptureState() -> UInt64 { 1 }
func probeLog(_ name: String, _ fields: [String: Any]) {}
final class LKRTCAudioEngineAvailability { var isInputAvailable: ObjCBool = false, isOutputAvailable: ObjCBool = false }
struct Availability { var isInputAvailable: NSNumber; var isOutputAvailable: NSNumber }
final class LKRTCAudioDeviceModule: @unchecked Sendable {
    var input = false, output = true, running = true
    var active = false, stopped = true, token: UInt64 = 0
    var observer: AnyObject?
    var isRecording: Bool { active }
    var isPlaying: Bool { running }
    func discardStoppedInputGraph() -> Int { 0 }
    func setEngineAvailability(_ value: LKRTCAudioEngineAvailability) -> Int { mutations += 1; onOrdinary?(); input = value.isInputAvailable.boolValue; output = value.isOutputAvailable.boolValue; if !output { running = false }; return 0 }
    func stopRecording() -> Int { active = false; return 0 }
    func stopPlayout() -> Int { running = false; return 0 }
    func setRecordingAlwaysPreparedMode(_ value: Bool) -> Int { 0 }
    var starts = 0, stops = 0, mutations = 0, reads = 0
    var startResult = 0, stopResult = 0
    var onRead: (() -> Void)?, onStart: (() -> Void)?, onOrdinary: (() -> Void)?
    var engineAvailability: Availability {
        reads += 1; onRead?(); return .init(isInputAvailable: NSNumber(value: input), isOutputAvailable: NSNumber(value: output))
    }
    var isEngineRunning: Bool { running }
    var privateInputMeterState: [String: Any] {
        ["supported": true, "confirmedStopped": stopped, "active": active,
         "startInFlight": false, "inputRunning": active, "cleanupUnconfirmed": false, "token": token]
    }
    func startPrivateInputMeter(token: UInt64) -> Int {
        starts += 1; self.token = token; stopped = false; onStart?()
        if startResult == 0 { active = true }; return startResult
    }
    func stopPrivateInputMeter(token: UInt64) -> Int {
        stops += 1; if stopResult == 0 { active = false; stopped = true }; return stopResult
    }
    func revokePrivateInputMeter(token: UInt64) { active = false }
}
final class LKRTCPeerConnectionFactory: @unchecked Sendable {
    let audioDeviceModule = LKRTCAudioDeviceModule()
}
final class GuestAudioOwnerLease { static var failures = 0; static func reportFailedStop() { failures += 1 } }
struct Meter { var resets = 0; mutating func reset() { resets += 1 } }
struct Profile { let usesPlatformVoiceProcessing = true }
struct Backend { let usesAudioEngine = true }
struct Renewal {
    enum Phase { case prepared, quarantined }; var resourcePhase: Phase { .prepared }
    func confirmShutdown() {}
    func invalidate(terminal: Bool = false) {}
    func markDirtyForPrivate(_ context: Int) -> Bool { false }
}
struct Trace {
    func enqueue(_ name: String, timeout: TimeInterval, deadlineUptime: TimeInterval?) -> Int { 1 }
    func timedOut(_ id: Int) {}; func start(_ id: Int) {}; func finish(_ id: Int, succeeded: Bool) {}
}

// INSERT PRODUCTION DECLARATIONS

final class Harness: @unchecked Sendable {
    let audioQueue = DispatchQueue(label: "private-check-test")
    let lock = NSLock()
    var stoppedPreparationHeld = false
    var operationTrace = Trace(), inputActivation = GuestInputActivationPolicy(persistent: false)
    var microphoneOptIn = false, privateInputLease = GuestPrivateInputLeasePolicy()
    var privateCheckAdmission = GuestPrivateCheckAdmission()
    var privateCheckFactory: LKRTCPeerConnectionFactory?
    var ownedFactory: LKRTCPeerConnectionFactory? = LKRTCPeerConnectionFactory()
    var ownerLease: GuestAudioOwnerLease?
    var failedStopOwner: Harness?, terminationRequested = false, closed = false, playoutEnabled = true
    var inputMeter = Meter()
    var inputMeterEnabled = false, inputCheckBegan: TimeInterval?, cached: [String: Any] = [:]
    let profile = Profile(), backend = Backend(), stoppedRenewal = Renewal(), isMeetingOwner = true
    let vpioPolicy = GuestVPIOReleasePolicy.builtInPreparedPrivateR3
    var currentModule: LKRTCAudioDeviceModule? { locked { ownedFactory?.audioDeviceModule } }
    var snapshot: [String: Any] { locked { cached } }
    func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    func update(_ value: [String: Any]) { locked { cached.merge(value) { _, new in new } } }
    func nativeCall<T>(_ name: String, _ body: () -> T) -> T { body() }
    func readSnapshot(_ module: LKRTCAudioDeviceModule) { update(["meterGraphOwners": module.running ? 1 : 0]) }
    func quarantineStoppedRenewal() { quarantinePrivateCheck() }
    func stoppedRenewalContext(_ module: LKRTCAudioDeviceModule, factory: LKRTCPeerConnectionFactory) -> Int { 0 }
    func isolatedPrivateInputStopped(_ module: LKRTCAudioDeviceModule) -> Bool { module.stopped && !module.active }

    // INSERT PRODUCTION METHODS

    func begin(_ id: UUID = UUID(), timeout: TimeInterval = 1) async -> Bool { await beginAdmittedPrivateCheck(id, timeout: timeout) }
    func end(_ id: UUID? = nil) async -> Bool { await endAdmittedPrivateCheck(id, timeout: 1) }
    func lateDrain(_ id: UUID) -> Bool { drainPrivateCheck(id, deadline: ProcessInfo.processInfo.systemUptime + 1) }
    var meter: Bool { locked { inputMeterEnabled } }
    var outstanding: UUID? { locked { privateCheckAdmission.ticket?.id } }
    func leave() { revokePrivateCheckAdmission(); locked { terminationRequested = true } }
    func networkPending() { revokePrivateCheckAdmission(pendingOnly: true) }
    func networkActivation() { revokePrivateCheckAdmission(pendingOnly: true); inputActivation.activate() }
    func holdQueue(_ entered: DispatchSemaphore, _ release: DispatchSemaphore) {
        audioQueue.async { entered.signal(); release.wait() }
    }
}

@main struct Tests {
    static var assertions = 0
    static func expect(_ value: Bool, _ message: String) {
        assertions += 1
        if !value {
            FileHandle.standardError.write(Data(("PRIVATE_CHECK_ASSERTION_FAILURE: " + message + "\n").utf8))
            preconditionFailure(message)
        }
    }
    static func main() async {
        // Test the actual typed selection against a deliberately stale cache.
        let context = GuestVPIOReleasePolicy.Context(meetingOwner: true, authorized: true, audioEngine: true,
            voiceProcessing: true, route: .builtIn, playoutRequested: true, outputRunning: false, inputAvailable: false)
        let native = GuestPrivateCheckAdmission.Observation(inputAvailable: false, outputAvailable: true, engineRunning: true, route: [77,70], capture: 1)
        expect(GuestVPIOReleasePolicy.builtInPreparedPrivateR3.privateCheck(context) == .existing, "original cached selector reproduces ordinary path")
        expect(GuestPrivateCheckAdmission.select(.builtInPreparedPrivateR3, context: context, before: native, after: native) == .isolated, "fresh running output selects isolated")
        for input in [false, true] {
            for output in [false, true] {
                for running in [false, true] {
                    let value = GuestPrivateCheckAdmission.Observation(inputAvailable: input, outputAvailable: output, engineRunning: running, route: [77,70], capture: 1)
                    let expected: GuestVPIOReleasePolicy.PrivateCheck = input ? .existing : (output && running ? .isolated : .notReady)
                    expect(GuestPrivateCheckAdmission.select(.builtInPreparedPrivateR3, context: context, before: value, after: value) == expected, "native state matrix")
                }
            }
        }
        for missing in 0..<3 {
            let value = GuestPrivateCheckAdmission.Observation(inputAvailable: missing == 0 ? nil : false,
                outputAvailable: missing == 1 ? nil : true, engineRunning: missing == 2 ? nil : true, route: [77,70], capture: 1)
            expect(GuestPrivateCheckAdmission.select(.builtInPreparedPrivateR3, context: context, before: value, after: value) == .notReady, "partial state fails closed")
        }
        let changed = GuestPrivateCheckAdmission.Observation(inputAvailable: false, outputAvailable: true, engineRunning: false, route: [77,70], capture: 1)
        expect(GuestPrivateCheckAdmission.select(.builtInPreparedPrivateR3, context: context, before: native, after: changed) == .notReady, "transition fails closed")

        var absolute = GuestPrivateCheckAdmission(); let absoluteID = UUID(), absoluteOwner = LKRTCPeerConnectionFactory()
        expect(absolute.reserve(id: absoluteID, owner: ObjectIdentifier(absoluteOwner), deadline: 10, now: 0), "absolute budget reserved")
        expect(!absolute.live(absoluteID, owner: ObjectIdentifier(absoluteOwner), now: 10), "deadline includes all admission work")
        expect(!absolute.commit(absoluteID, owner: ObjectIdentifier(absoluteOwner), now: 11), "late commit rejected independently of timer")
        let happy = Harness(); happy.cached = ["engineRunning": false, "inputAvailable": false, "outputAvailable": true]
        expect(await happy.begin(), "actual admission ignores stale cached output")
        expect(happy.inputMeter.resets == 1, "meter resets before request commit")
        expect(happy.currentModule!.starts == 1 && happy.currentModule!.mutations == 0 && happy.meter, "isolated only and meter committed")
        expect(await happy.end(), "happy drain")
        expect(happy.outstanding == nil && !happy.meter, "drained slot")
        let pending = Harness(); pending.currentModule!.running = false
        expect(!(await pending.begin()), "pending output rejects")
        expect(pending.currentModule!.starts == 0 && pending.currentModule!.mutations == 0, "no destructive fallback")
        let soundOff = Harness(); soundOff.playoutEnabled = false
        expect(await soundOff.begin(), "Sound off ordinary remains supported"); expect(await soundOff.end(), "ordinary drain")
        let persistent = Harness(); persistent.inputActivation.activate(); persistent.microphoneOptIn = true; persistent.currentModule!.input = true
        expect(await persistent.begin(), "persistent ordinary supported"); expect(await persistent.end(), "persistent drain")
        expect(persistent.currentModule!.input, "persistent input survives end")

        // Production queue/deadline code, with controllable worker boundaries.
        for event in ["cancel", "leave", "soundABA", "expire", "replace"] {
            for boundary in ["queue", "snapshot", "entrySnapshot", "start"] {
                let h = Harness(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
                let module = h.currentModule!
                if boundary == "queue" { h.holdQueue(entered, release) }
                if boundary == "snapshot" { module.onRead = { if module.reads == 1 { entered.signal(); release.wait() } } }
                if boundary == "entrySnapshot" { module.onRead = { if module.reads == 3 { entered.signal(); release.wait() } } }
                if boundary == "start" { module.onStart = { entered.signal(); release.wait() } }
                let task = Task.detached { await h.begin(timeout: event == "expire" ? 0.03 : 1) }
                let reached = await withCheckedContinuation { continuation in
                    DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 2) == .success) }
                }
                expect(reached, "requested native boundary reached")
                switch event {
                case "cancel": task.cancel()
                case "leave": h.leave()
                case "soundABA": h.setLocalPlayoutIntent(false); h.setLocalPlayoutIntent(true)
                case "replace": h.locked { h.ownedFactory = LKRTCPeerConnectionFactory() }
                default: try? await Task.sleep(nanoseconds: 50_000_000)
                }
                release.signal(); let result = await task.value
                expect(!result && !h.meter, "\(event) at \(boundary) cannot commit")
                if boundary != "start" { expect(module.starts == 0, "revoked before native start") }
                if boundary == "start" { expect(module.stops == 1, "in-flight native start drained") }
            }
        }
        for event in ["cancel", "soundABA", "network"] {
            let h = Harness(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            h.playoutEnabled = false
            let module = h.currentModule!
            module.onOrdinary = { if module.mutations == 1 { entered.signal(); release.wait() } }
            let task = Task.detached { await h.begin() }
            let reached = await withCheckedContinuation { continuation in
                DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 2) == .success) }
            }
            expect(reached, "ordinary mutation boundary reached")
            if event == "cancel" { task.cancel() }
            if event == "soundABA" { h.setLocalPlayoutIntent(true); h.setLocalPlayoutIntent(false) }
            if event == "network" { h.networkPending() }
            release.signal()
            expect(!(await task.value) && !h.meter, "ordinary stale commit rejected")
            expect(!module.input && h.outstanding == nil, "ordinary rollback drained before successor")
            if event == "network" { h.inputActivation.activate(); h.microphoneOptIn = true; module.input = true }
            expect(await h.begin(), "ordinary successor after exact rollback")
            expect(await h.end(), "ordinary successor drains")
            if event == "network" { expect(module.input, "network persistent activation survives old rollback") }
        }
        for drift in ["running", "route"] {
            let h = Harness(), module = h.currentModule!
            module.onRead = {
                if module.reads == 3 {
                    if drift == "running" { module.running = false }
                    if drift == "route" { GuestVPIOBuiltInRoute.route = [78,70] }
                }
            }
            expect(!(await h.begin()), "native state drift before entry rejects")
            expect(module.starts == 0 && module.mutations == 0, "drift has no native start or fallback")
            GuestVPIOBuiltInRoute.route = [77,70]
        }
        let ordinaryDrift = Harness(); ordinaryDrift.playoutEnabled = false
        let ordinaryModule = ordinaryDrift.currentModule!
        ordinaryModule.onRead = { if ordinaryModule.reads == 3 { ordinaryModule.running = false } }
        expect(!(await ordinaryDrift.begin()), "ordinary native-entry hook must execute and reject drift")
        expect(ordinaryModule.starts == 0 && !ordinaryModule.input, "ordinary drift rollback remains capture-off")
        let failed = Harness(); failed.currentModule!.startResult = -5001
        expect(!(await failed.begin()), "-5001 stays failure"); expect(failed.currentModule!.mutations == 0, "no native failure fallback")
        let quarantine = Harness(); quarantine.currentModule!.startResult = -5001; quarantine.currentModule!.stopResult = -5001
        expect(!(await quarantine.begin()), "failed stop stays failure"); expect(quarantine.privateInputLease.quarantined, "unconfirmed cleanup quarantined")
        expect(!(await quarantine.begin()), "quarantine blocks successor")

        let sequence = Harness(), a = UUID(), b = UUID()
        expect(await sequence.begin(a), "A starts"); expect(!(await sequence.begin(b)), "B blocked while A outstanding")
        expect(await sequence.end(a), "A ends"); expect(await sequence.begin(b), "B starts after drain")
        expect(await sequence.end(a), "late A cleanup is harmless"); expect(sequence.lateDrain(a), "late queued A drain is harmless"); expect(sequence.meter && sequence.outstanding == b && sequence.currentModule!.active, "late A cannot disable B")
        sequence.setLocalPlayoutIntent(false); sequence.setLocalPlayoutIntent(true)
        expect(sequence.meter, "committed check preserves existing Sound behavior")
        expect(await sequence.end(b), "B drains")
        let leaving = Harness(); expect(await leaving.begin(), "active check before shutdown")
        weak var retainedFactory = leaving.ownedFactory
        expect(await leaving.shutdown(), "actual confirmed shutdown succeeds")
        expect(leaving.outstanding == nil && leaving.privateCheckFactory == nil && retainedFactory == nil, "confirmed shutdown retires admission and factory")
        let lostOwner = Harness(); expect(await lostOwner.begin(), "active check before lost current owner")
        lostOwner.locked { lostOwner.ownedFactory = nil }
        expect(!(await lostOwner.shutdown()), "missing current owner is not stop proof")
        expect(lostOwner.privateCheckFactory != nil && lostOwner.outstanding != nil, "missing owner retains exact authority")
        let failedLeave = Harness(); expect(await failedLeave.begin(), "active check before failed shutdown")
        failedLeave.currentModule!.stopResult = -5001
        expect(!(await failedLeave.shutdown()), "failed shutdown remains failure")
        expect(failedLeave.privateCheckFactory != nil && failedLeave.outstanding != nil, "failed stop retains exact owner")
        print("PASS \(assertions) assertions; production extracted selection, ticket, admission, drain, Sound latch and queue timeout methods")
    }
}
