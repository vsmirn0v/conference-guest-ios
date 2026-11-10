private final class FixtureOwner {
    let identity: UInt
    init(_ identity: UInt) { self.identity = identity }
}
private final class Fixture {
    var time = 100.0
    lazy var renewal = GuestStoppedInputRenewal(now: { self.time })
    var context = GuestStoppedInputRenewal.Context(owner: 41, route: [1, 2], captureState: 7,
        authorized: true, policyEligible: true, captureClosed: true, inputOptedIn: false,
        inputAvailable: false, outputAvailable: false, engineRunning: false, soundOn: false, terminal: false)
    var queue: [() -> Void] = [], timers: [(Double, () -> Void)] = []
    var events: [String] = [], receipts: [GuestStoppedInputRenewal.Receipt] = []
    var prepared: (() -> Void)?, beforeRestore: (() -> Void)?, duringRestore: (() -> Void)?
    var retiringStale: (() -> Void)?, staleRetirementResult: Int?, staleRetirementCount = 0
    var onHold: (() -> Void)?
    var prepareResult = 0, discardFailure = false, quietSuccess = true, restoreSuccess = true, reconciliationSuccess = true
    var generation = 1, cache: Int? = 1, held = false, prepareCount = 0, restoreCount = 0, discardCount = 0
    var restorationDeadlines: [Double] = []
    var rawInputEnabled = true, rawInputRunning = true, rawOutputEnabled = true, rawOutputRunning = true
    var expectedDemand = [true, true, true, true]
    weak var owner: FixtureOwner?
    var retainedOwner: FixtureOwner?
    func makeDebt() {
        renewal.markPrepared(0)
        precondition(renewal.markDirtyForPrivate(context))
        precondition(cache == 1 && renewal.resourcePhase == .refreshRequired && renewal.stoppedCacheOwnership == .retained)
        context.soundOn = true; renewal.invalidate()
    }
    func fireTimers() {
        let due = timers.filter { $0.0 <= time }; timers.removeAll { $0.0 <= time }
        due.forEach { $0.1() }
    }
    func drain() { while !queue.isEmpty { queue.removeFirst()() } }
    func request() async -> GuestStoppedInputRenewal.Outcome {
        await renewal.request(authority: context.authority, enqueue: { self.queue.append($0) },
            schedule: { self.timers.append(($0, $1)) }, execute: { ticket in
                let owner = FixtureOwner(ticket.owner); self.owner = owner
                withExtendedLifetime(owner) {
                    self.renewal.run(ticket, hooks: .init(
                        context: { self.context },
                        hold: { self.held = $0; self.events.append($0 ? "hold" : "hold-cleared"); if $0 { self.onHold?() } },
                        prepare: {
                            precondition(self.held && self.context.physicallyOff && self.cache == nil)
                            self.prepareCount += 1; self.events.append("prepare-begin")
                            self.prepared?()
                            if self.prepareResult == 0 {
                                self.generation += 1; self.cache = self.generation
                                self.events.append("cache-\(self.generation)")
                            }
                            self.events.append("prepare-return"); return self.prepareResult
                        },
                        retireStale: {
                            precondition(self.held && self.context.physicallyOff)
                            self.staleRetirementCount += 1; self.events.append("stale-retire-begin-owner-\(owner.identity)")
                            self.retiringStale?()
                            let result = self.staleRetirementResult ?? (self.cache == nil ? 1 : 0)
                            if result == 0 || result == 1 { self.cache = nil }
                            self.events.append("stale-retire-return-\(result)"); return result
                        },
                        restore: { deadline, admitted in
                            self.restoreCount += 1; self.restorationDeadlines.append(deadline)
                            self.beforeRestore?()
                            guard admitted() else { return false }
                            precondition(!self.held)
                            self.events.append("output-start")
                            self.context.outputAvailable = true; self.context.engineRunning = true
                            self.duringRestore?()
                            return self.restoreSuccess && admitted()
                        },
                        quiet: {
                            self.events.append("quiet")
                            if self.quietSuccess {
                                self.context.inputAvailable = false; self.context.outputAvailable = false
                                self.context.engineRunning = false
                            }
                            return self.quietSuccess
                        },
                        reconcileLatest: {
                            self.events.append("reconcile-latest")
                            return self.renewal.reconcileLatest(context: { self.context }, apply: { target in
                                self.events.append("restrict-\(target.input)-\(target.output)")
                                guard self.reconciliationSuccess else { return false }
                                self.context.inputAvailable = target.input; self.context.outputAvailable = target.output
                                if !target.input && !target.output { self.context.engineRunning = false }
                                return true
                            })
                        },
                        discard: {
                            self.discardCount += 1; self.events.append("discard-owner-\(owner.identity)-cache-\(self.cache ?? 0)")
                            if self.discardFailure { return -1 }
                            let result = self.cache == nil ? 1 : 0; self.cache = nil; return result
                        },
                        quarantine: { self.retainedOwner = owner; self.events.append("quarantine") },
                        report: { self.receipts.append($0) }))
                }
            })
    }
    func checkRawDemand() {
        precondition([rawInputEnabled, rawInputRunning, rawOutputEnabled, rawOutputRunning] == expectedDemand)
    }
}
/// Native/platform boundary fake; the handler, notification and intent policy
/// under test are the actual NativeDesktopHeadsetMute source extracted by runner.
@MainActor private final class HeadsetPlatformFixture {
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 1
        var state: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ muted: Bool) {
            lock.lock(); value = ((value & ~1) + 2) | (muted ? 1 : 0); lock.unlock()
        }
        func open(_ expected: UInt64) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard value == expected else { return false }
            value = ((value & ~1) + 2); return true
        }
    }
    let gate = Gate()
    var muted = true, reconfiguring = false
    var handler: (@Sendable (Bool) -> Bool)?
    var observer: (@MainActor (Bool) -> Void)?
    var platform: NativeDesktopHeadsetMute.Platform {
        .init(available: true, readMuted: { self.muted }, writeMuted: {
            self.muted = $0; precondition(self.handler?($0) == true)
        }, install: { self.handler = $0 }, uninstall: {}, observe: { self.observer = $0; return NSObject() },
        removeObserver: { _ in }, setCaptureMuted: { [gate] in gate.set($0) }, captureState: { [gate] in gate.state },
        unmuteIfState: { [gate] in gate.open($0) }, setIntent: { _ in }, isReconfiguring: { self.reconfiguring })
    }
    func deliver(_ muted: Bool) {
        self.muted = muted; precondition(handler?(muted) == true); observer?(muted)
    }
    func sync(_ fixture: Fixture) {
        fixture.context.captureState = gate.state
        fixture.context.captureClosed = gate.state & 1 != 0
    }
}
@MainActor private func start(_ fixture: Fixture) async -> Task<GuestStoppedInputRenewal.Outcome, Never> {
    let task = Task { @MainActor in await fixture.request() }
    for _ in 0..<1000 {
        if !fixture.queue.isEmpty { return task }
        await Task.yield()
    }
    preconditionFailure("request did not enqueue")
}
@main private struct RenewalOrchestrationTests {
    @MainActor static func main() async {
        var count = 0
        func pass(_ name: String, _ fixture: Fixture) {
            fixture.checkRawDemand(); count += 1; print("PASS \(name)")
        }
        do {
            let f = Fixture(); f.makeDebt(); let t = await start(f); f.drain()
            let outcome = await t.value; precondition(outcome == .prepared)
            precondition(f.prepareCount == 1 && f.restoreCount == 1 && f.discardCount == 0)
            precondition(f.cache == 2 && f.renewal.resourcePhase == .prepared && !f.held)
            precondition(f.receipts[0].nativeResult == 0 && f.restorationDeadlines == [102])
            f.time = 200; f.fireTimers(); precondition(f.cache == 2 && f.receipts.count == 1)
            pass("exact-zero preparation and one completion", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); f.prepareResult = 1
            let t = await start(f); f.drain(); let outcome = await t.value; precondition(outcome == .skipped)
            precondition(f.cache == nil && f.renewal.resourcePhase == .absent && f.restoreCount == 1)
            precondition(f.receipts[0].nativeResult == 1 && f.receipts[0].outcome != .prepared)
            pass("clean skip restores ordinary Sound but never certifies prepared", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); f.prepareResult = -5001
            let t = await start(f); f.drain(); let outcome = await t.value; precondition(outcome == .failed)
            precondition(f.restoreCount == 0 && f.discardCount == 1 && f.receipts[0].cleanupConfirmed)
            pass("native failure retires or confirms absent before retry eligibility", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); let t = await start(f)
            f.time = 109; f.fireTimers(); let outcome = await t.value; precondition(outcome == .timedOut)
            precondition(f.renewal.snapshot["stoppedInputRenewalPending"] as? Bool == true)
            precondition(f.renewal.snapshot["cleanupSucceeded"] as? Bool == false)
            f.drain(); precondition(f.prepareCount == 0 && f.restoreCount == 0 && f.discardCount == 0)
            precondition(f.renewal.snapshot["stoppedInputRenewalPending"] as? Bool == false)
            pass("expired queued work performs no native call", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); let t = await start(f)
            f.time = 102.1; f.drain(); let outcome = await t.value; precondition(outcome == .timedOut)
            precondition(f.prepareCount == 0)
            pass("queue delay cannot reset native six-second budget", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); f.prepared = {
                f.time = 109; f.fireTimers()
                precondition(f.owner != nil && f.held)
                f.renewal.invalidate(); f.context.captureState += 2
                f.queue.append {
                    precondition(f.cache == nil && !f.held)
                    f.events.append("newer-activation")
                    f.cache = 3; f.events.append("newer-cache-3")
                }
            }
            let t = await start(f); f.drain(); let outcome = await t.value; precondition(outcome == .timedOut)
            precondition(f.restoreCount == 0 && f.discardCount == 1 && f.cache == 3)
            let discard = f.events.firstIndex(where: { $0.hasPrefix("discard-owner-41") })!
            precondition(discard < f.events.firstIndex(of: "newer-activation")!)
            precondition(f.owner == nil)
            f.time = 200; f.fireTimers(); precondition(f.cache == 3)
            pass("late zero retires old cache before newer activation and cannot delete replacement", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); var t: Task<GuestStoppedInputRenewal.Outcome, Never>!
            f.prepared = { t.cancel() }; t = await start(f); f.drain()
            let outcome = await t.value; precondition(outcome == .cancelled)
            precondition(f.discardCount == 1 && f.restoreCount == 0 && f.cache == nil && !f.held)
            pass("in-flight cancellation drains late native zero", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); let t = await start(f); t.cancel()
            for _ in 0..<10 { await Task.yield() }
            f.drain(); let outcome = await t.value; precondition(outcome == .cancelled); precondition(f.prepareCount == 0)
            pass("queued cancellation performs no preparation", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); let t = await start(f)
            f.context.terminal = true; f.renewal.invalidate(terminal: true)
            f.drain(); let outcome = await t.value; precondition(outcome == .superseded); precondition(f.prepareCount == 0)
            pass("queued Leave closes owner before native work", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); f.prepared = { f.context.terminal = true; f.renewal.invalidate(terminal: true) }
            let t = await start(f); f.drain(); let outcome = await t.value; precondition(outcome == .superseded)
            precondition(f.restoreCount == 0 && f.discardCount == 1 && f.cache == nil)
            pass("in-flight Leave retires before shutdown queue can advance", f)
        }
        for kind in ["Sound ABA", "Mic ABA"] {
            let f = Fixture(); f.makeDebt(); f.prepared = {
                if kind == "Sound ABA" { f.context.soundOn = false; f.renewal.invalidate(); f.context.soundOn = true; f.renewal.invalidate() }
                else { f.renewal.invalidate(); f.context.captureState += 2; f.renewal.invalidate(); f.context.captureState += 2 }
            }
            let t = await start(f); f.drain(); let outcome = await t.value; precondition(outcome == .superseded)
            precondition(f.restoreCount == 0 && f.discardCount == 1)
            pass("\(kind) cannot revive old Boolean intent", f)
        }
        for change in ["owner", "route", "capture", "permission"] {
            let f = Fixture(); f.makeDebt(); f.prepared = {
                switch change {
                case "owner": f.context.owner = 42
                case "route": f.context.route = [3, 4]
                case "capture": f.context.captureState += 1; f.context.captureClosed = false
                default: f.context.authorized = false
                }
            }
            let t = await start(f); f.drain(); let outcome = await t.value; precondition(outcome == .superseded)
            precondition(f.restoreCount == 0 && f.discardCount == 1)
            precondition(f.events.contains { $0.hasPrefix("discard-owner-41") })
            pass("\(change) invalidation retires exact retained owner", f)
        }
        for change in ["owner", "route", "capture", "permission"] {
            let f = Fixture(); f.makeDebt(); let t = await start(f)
            switch change {
            case "owner": f.context.owner = 42
            case "route": f.context.route = [3, 4]
            case "capture": f.context.captureState += 1; f.context.captureClosed = false
            default: f.context.authorized = false
            }
            f.drain(); let outcome = await t.value; precondition(outcome == .superseded)
            precondition(f.prepareCount == 0 && f.restoreCount == 0)
            pass("queued \(change) invalidation cannot reserve another authority", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); f.prepared = {
                f.renewal.observeRoute([3, 4]); f.renewal.observeRoute([1, 2])
            }
            let t = await start(f); f.drain(); let outcome = await t.value; precondition(outcome == .superseded)
            precondition(f.discardCount == 1 && f.restoreCount == 0)
            pass("observed device ABA revokes even when final device IDs match", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); f.prepared = { f.time += 6.1 }
            let t = await start(f); f.drain(); let outcome = await t.value; precondition(outcome == .timedOut)
            precondition(f.discardCount == 1 && f.restoreCount == 0)
            pass("native preparation ceiling enforced without renewing caller deadline", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); f.prepared = { f.time += 5.5 }
            f.duringRestore = { f.time += 1 }
            let t = await start(f); f.drain(); let outcome = await t.value; precondition(outcome == .prepared)
            precondition(f.restorationDeadlines == [107.5] && f.receipts[0].deadline == 108)
            pass("restore shares original deadline and retains two-second stage ceiling", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); f.time = 100
            f.prepared = { f.time += 5.9 }; f.duringRestore = { f.time += 2.2; f.fireTimers() }
            let t = await start(f); f.drain(); let outcome = await t.value; precondition(outcome == .timedOut)
            precondition(f.cache == nil && f.discardCount == 1 && !f.context.outputAvailable)
            pass("late restore converges physical off and retires cache", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); f.beforeRestore = { f.renewal.invalidate(); f.context.soundOn = false }
            let t = await start(f); f.drain(); let outcome = await t.value; precondition(outcome == .superseded)
            precondition(!f.events.contains("output-start") && f.discardCount == 1)
            pass("pre-adoption invalidation starts no obsolete output", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); f.duringRestore = { f.context.soundOn = false; f.renewal.invalidate() }
            let t = await start(f); f.drain(); let outcome = await t.value; precondition(outcome == .superseded)
            precondition(f.events.firstIndex(of: "output-start")! < f.events.firstIndex(of: "quiet")!)
            precondition(!f.context.outputAvailable && !f.held && f.cache == nil)
            pass("new off during already-admitted native restore converges off before next queue work", f)
        }
        for failure in ["discard", "quiet"] {
            let f = Fixture(); f.makeDebt(); f.discardFailure = failure == "discard"; f.quietSuccess = failure != "quiet"
            f.prepared = { f.time = 109; f.fireTimers() }
            let t = await start(f); f.drain(); let outcome = await t.value; precondition(outcome == .timedOut)
            precondition(f.renewal.resourcePhase == .quarantined && f.retainedOwner != nil && f.held)
            precondition(f.receipts[0].outcome == .cleanupUnconfirmed && !f.receipts[0].cleanupConfirmed)
            let retry = await f.request(); precondition(retry == .failed && f.queue.isEmpty)
            pass("failed \(failure) retains complete owner and blocks replacement", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); let a = await start(f)
            let b = Task { @MainActor in await f.request() }
            for _ in 0..<1000 {
                if f.renewal.snapshot["stoppedInputRenewalWaiters"] as? Int == 2 { break }
                await Task.yield()
            }
            precondition(f.queue.count == 1)
            a.cancel(); for _ in 0..<10 { await Task.yield() }
            f.drain(); let outcomeA = await a.value, outcomeB = await b.value; precondition(outcomeA == .cancelled && outcomeB == .prepared)
            precondition(f.prepareCount == 1 && f.restoreCount == 1)
            pass("coalesced same-intent waiter cancellation cannot cancel another waiter", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); f.context.soundOn = false
            f.time = 500; f.fireTimers(); f.drain()
            precondition(f.queue.isEmpty && f.prepareCount == 0 && f.staleRetirementCount == 0 && f.cache == 1 && f.owner == nil)
            f.renewal.invalidate(terminal: true)
            let outcome = await f.request(); precondition(outcome == .failed)
            pass("no Sound restoration keeps stale cache without background work or extra transaction owner retention", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); f.context.inputOptedIn = true; f.context.inputAvailable = true
            f.beforeRestore = { f.renewal.invalidate() }
            let t = await start(f); f.drain(); let outcome = await t.value; precondition(outcome == .superseded)
            precondition(f.prepareCount == 0 && f.discardCount == 0 && f.context.inputAvailable && !f.events.contains("quiet"))
            pass("ineligible active input is never stopped by obsolete skipped work", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); let a = await start(f)
            f.renewal.invalidate()
            let b = Task { @MainActor in await f.request() }
            for _ in 0..<1000 { if f.queue.count == 2 { break }; await Task.yield() }
            precondition(f.queue.count == 2); a.cancel(); f.drain()
            let oa = await a.value, ob = await b.value
            precondition(oa == .superseded && ob == .prepared && f.prepareCount == 1)
            f.time = 200; f.fireTimers(); precondition(f.cache == 2 && f.renewal.resourcePhase == .prepared)
            pass("old cancellation and timeout cannot revoke or delete newer generation", f)
        }
        do {
            let f = Fixture(); f.renewal.markPrepared(0); f.context.outputAvailable = true; f.context.engineRunning = true
            let dirtied = f.renewal.markDirtyForPrivate(f.context)
            precondition(!dirtied && f.renewal.resourcePhase == .prepared && f.cache == 1)
            pass("ordinary borrow never disposes prepared resource beside live output", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); f.staleRetirementResult = -1
            let t = await start(f); f.drain(); let failed = await t.value
            precondition(failed == .cleanupUnconfirmed && f.renewal.resourcePhase == .quarantined)
            f.renewal.markPrepared(0); precondition(f.renewal.resourcePhase == .quarantined)
            let outcome = await f.request(); precondition(outcome == .failed && f.retainedOwner != nil)
            pass("failed deferred stale retirement quarantines and cannot be re-marked prepared", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); f.prepared = { f.context.engineRunning = true }
            let t = await start(f); f.drain(); let outcome = await t.value; precondition(outcome == .failed)
            precondition(f.restoreCount == 0 && f.discardCount == 1 && !f.context.engineRunning)
            pass("native zero with observed physical activity fails and drains", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); f.prepared = {
                f.rawInputRunning = false; f.rawOutputRunning = false
                f.expectedDemand = [true, false, true, false]
            }
            let t = await start(f); f.drain(); let outcome = await t.value; precondition(outcome == .prepared)
            pass("new peer demand remains current without saved-demand replay", f)
        }
        // BEGIN SKIPPED RESTORE REGRESSIONS
        do {
            let f = Fixture(); f.makeDebt()
            f.context.inputOptedIn = true; f.context.inputAvailable = true; f.context.engineRunning = true
            var successorState: [Bool] = []
            f.duringRestore = {
                f.context.soundOn = false; f.renewal.invalidate()
                f.queue.append { successorState = [f.context.inputAvailable, f.context.outputAvailable]; f.events.append("successor") }
            }
            let t = await start(f); f.drain(); let outcome = await t.value
            precondition(outcome == .superseded)
            precondition(successorState == [true, false], "skipped Sound-off did not converge before successor")
            precondition(f.context.inputAvailable && !f.context.outputAvailable)
            precondition(f.prepareCount == 0 && f.discardCount == 0 && !f.events.contains("quiet"))
            pass("in-flight skipped Sound-off withdraws output before successor and preserves active input", f)
        }
        do {
            let f = Fixture(); f.makeDebt()
            f.context.inputOptedIn = true; f.context.inputAvailable = true; f.context.engineRunning = true
            var successorState: [Bool] = []
            f.duringRestore = {
                f.context.terminal = true; f.renewal.invalidate(terminal: true)
                f.queue.append { successorState = [f.context.inputAvailable, f.context.outputAvailable]; f.events.append("successor") }
            }
            let t = await start(f); f.drain(); let outcome = await t.value
            precondition(outcome == .superseded)
            precondition(successorState == [false, false], "skipped Leave did not converge before successor")
            precondition(!f.context.engineRunning && f.prepareCount == 0 && f.discardCount == 0)
            pass("in-flight skipped Leave closes both paths before successor", f)
        }
        // END SKIPPED RESTORE REGRESSIONS
        do {
            let f = Fixture(); f.makeDebt()
            f.context.inputOptedIn = true; f.context.inputAvailable = true; f.context.engineRunning = true
            f.duringRestore = { f.time = 109; f.fireTimers() }
            let t = await start(f); f.drain(); let outcome = await t.value
            precondition(outcome == .timedOut && f.context.soundOn)
            precondition(f.context.inputAvailable && !f.context.outputAvailable && f.discardCount == 0)
            precondition(f.receipts[0].latestReconciliation == true && f.receipts[0].cleanupConfirmed)
            f.duringRestore = nil
            let fresh = await start(f); f.drain(); let freshOutcome = await fresh.value
            precondition(freshOutcome == .skipped && f.context.outputAvailable && f.context.inputAvailable)
            pass("expired skipped request is physically off despite old on intent; fresh request restores under new authority", f)
        }
        do {
            let f = Fixture(); f.makeDebt()
            f.context.inputOptedIn = true; f.context.inputAvailable = true; f.context.engineRunning = true
            f.restoreSuccess = false
            let t = await start(f); f.drain(); let outcome = await t.value
            precondition(!outcome.restored && !f.context.outputAvailable && f.context.inputAvailable)
            precondition(f.prepareCount == 0 && f.discardCount == 0 && f.receipts[0].cleanupConfirmed)
            pass("failed skipped native restore withdraws its output and preserves authorized input", f)
        }
        do {
            let f = Fixture(); f.makeDebt()
            f.context.inputOptedIn = true; f.context.inputAvailable = true; f.context.engineRunning = true
            f.reconciliationSuccess = false
            f.duringRestore = { f.context.soundOn = false; f.renewal.invalidate() }
            let t = await start(f); f.drain(); let outcome = await t.value
            precondition(outcome == .superseded && f.renewal.resourcePhase == .quarantined)
            precondition(f.retainedOwner != nil && !f.receipts[0].cleanupConfirmed && f.receipts[0].latestReconciliation == false)
            precondition(f.context.outputAvailable && f.context.inputAvailable && f.discardCount == 0)
            let blocked = await f.request(); precondition(blocked == .failed)
            pass("failed skipped convergence retains exact owner and reports quarantine rather than physical off", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); let platform = HeadsetPlatformFixture()
            let headset = NativeDesktopHeadsetMute(platform: platform.platform)
            var semanticRequests = 0
            precondition(headset.begin(onRequestedMute: { _ in semanticRequests += 1; f.renewal.invalidate() }))
            platform.sync(f); let old = platform.gate.state
            f.prepared = {
                platform.reconfiguring = true; platform.deliver(true); platform.sync(f)
                precondition(platform.gate.state != old && !platform.gate.open(old))
                platform.reconfiguring = false
            }
            let t = await start(f); f.drain(); let outcome = await t.value
            precondition(outcome == .prepared && semanticRequests == 0 && f.discardCount == 0)
            precondition(platform.gate.state & 1 != 0 && f.context.captureClosed)
            headset.end()
            pass("real headset repair advances closed PCM epoch without revoking stopped resource or accepting old CAS", f)
        }
        for event in ["external mute", "external unmute", "external ABA"] {
            let f = Fixture(); f.makeDebt(); let platform = HeadsetPlatformFixture()
            let headset = NativeDesktopHeadsetMute(platform: platform.platform)
            var semanticRequests: [Bool] = []
            precondition(headset.begin(onRequestedMute: { semanticRequests.append($0); f.renewal.invalidate() }))
            if event == "external mute" { _ = headset.requestIntent(muted: false) }
            platform.sync(f)
            f.prepared = {
                switch event {
                case "external mute": platform.deliver(true)
                case "external unmute": platform.deliver(false)
                default: platform.deliver(false); platform.deliver(true)
                }
                platform.sync(f)
            }
            let t = await start(f); f.drain(); let outcome = await t.value
            precondition(outcome == .superseded && !semanticRequests.isEmpty && f.discardCount == 1 && f.restoreCount == 0)
            precondition(platform.gate.state & 1 != 0)
            headset.end()
            pass("real headset \(event) independently revokes renewal while PCM stays closed", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); let platform = HeadsetPlatformFixture()
            let headset = NativeDesktopHeadsetMute(platform: platform.platform)
            precondition(headset.begin(onRequestedMute: { _ in f.renewal.invalidate() }))
            let request = headset.requestIntent(muted: false); platform.sync(f)
            f.prepared = { headset.confirm(muted: false, request: request); platform.sync(f) }
            let t = await start(f); f.drain(); let outcome = await t.value
            precondition(outcome == .superseded && !f.context.captureClosed && f.discardCount == 1)
            headset.end()
            pass("actual headset confirmed opening invalidates stopped renewal", f)
        }
        // BEGIN DEFERRED RETIREMENT REGRESSIONS
        do {
            let f = Fixture(); f.makeDebt()
            precondition(f.cache == 1 && f.staleRetirementCount == 0 && f.discardCount == 0 && f.prepareCount == 0)
            precondition(f.renewal.resourcePhase == .refreshRequired && f.renewal.stoppedCacheOwnership == .retained)
            precondition(f.renewal.snapshot["stoppedInputCacheOwnership"] as? String == "retained")
            precondition(!f.renewal.markDirtyForPrivate(f.context) && f.cache == 1)
            pass("private admission marks debt while retaining the same stopped cache without native disposal", f)
        }
        do {
            let f = Fixture(); f.makeDebt()
            f.retiringStale = { precondition(f.owner?.identity == 41 && f.cache == 1 && f.held) }
            let t = await start(f); f.drain(); let outcome = await t.value
            precondition(outcome == .prepared && f.staleRetirementCount == 1 && f.prepareCount == 1 && f.restoreCount == 1)
            let retired = f.events.firstIndex(of: "stale-retire-return-0")!
            precondition(retired < f.events.firstIndex(of: "prepare-begin")! && f.events.firstIndex(of: "prepare-return")! < f.events.firstIndex(of: "output-start")!)
            precondition(f.receipts[0].staleRetirementResult == 0 && f.receipts[0].nativeResult == 0 && f.cache == 2)
            precondition(f.renewal.stoppedCacheOwnership == .retained)
            pass("same-owner held stale retirement precedes fresh native zero and output restore", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); f.cache = nil
            let t = await start(f); f.drain(); let outcome = await t.value
            precondition(outcome == .prepared && f.receipts[0].staleRetirementResult == 1 && f.staleRetirementCount == 1)
            precondition(f.prepareCount == 1 && f.cache == 2 && f.renewal.stoppedCacheOwnership == .retained)
            pass("stale retirement clean one confirms absence before replacement preparation", f)
        }
        do {
            let f = Fixture(); f.makeDebt()
            f.retiringStale = {
                f.time = 109; f.fireTimers()
                precondition(f.owner?.identity == 41 && f.held)
                precondition(f.renewal.snapshot["stoppedInputRenewalPending"] as? Bool == true)
                precondition(f.renewal.snapshot["cleanupSucceeded"] as? Bool == false)
                f.queue.append {
                    precondition(f.cache == nil && !f.held && f.prepareCount == 0 && f.restoreCount == 0)
                    f.cache = 3; f.renewal.markPrepared(0); f.events.append("successor-cache-3")
                }
            }
            let t = await start(f); f.drain(); let outcome = await t.value
            precondition(outcome == .timedOut && f.staleRetirementCount == 1 && f.discardCount == 0)
            precondition(f.receipts[0].cleanupConfirmed && f.receipts[0].staleRetirementResult == 0 && f.owner == nil)
            f.time = 200; f.fireTimers()
            precondition(f.cache == 3 && f.renewal.resourcePhase == .prepared && f.renewal.stoppedCacheOwnership == .retained)
            pass("late stale retirement drains before successor and old expiry cannot delete a newer cache", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); var t: Task<GuestStoppedInputRenewal.Outcome, Never>!
            f.retiringStale = { precondition(f.owner != nil && f.held); t.cancel() }
            t = await start(f); f.drain(); let outcome = await t.value
            precondition(outcome == .cancelled && f.cache == nil && f.prepareCount == 0 && f.restoreCount == 0)
            precondition(f.staleRetirementCount == 1 && f.discardCount == 0 && f.receipts[0].cleanupConfirmed && !f.held && f.owner == nil)
            precondition(f.renewal.stoppedCacheOwnership == .absent && f.renewal.resourcePhase == .refreshRequired)
            pass("cancellation during stale retirement retains owner through drain and admits no forward work", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); var shutdownReached = false
            f.retiringStale = {
                f.context.terminal = true; f.renewal.invalidate(terminal: true)
                f.queue.append {
                    precondition(f.cache == nil && !f.held && !f.context.engineRunning)
                    f.renewal.confirmShutdown(); shutdownReached = true
                }
            }
            let t = await start(f); f.drain(); let outcome = await t.value
            precondition(outcome == .superseded && shutdownReached && f.prepareCount == 0 && f.restoreCount == 0)
            precondition(f.receipts[0].cleanupConfirmed && f.staleRetirementCount == 1 && f.discardCount == 0)
            precondition(f.renewal.resourcePhase == .absent && f.renewal.stoppedCacheOwnership == .absent)
            let blocked = await f.request(); precondition(blocked == .failed)
            pass("Leave during stale retirement drains before shutdown and cannot restore or resurrect owner", f)
        }
        do {
            let f = Fixture(); f.makeDebt()
            f.retiringStale = { f.time += 2.1 }
            let t = await start(f); f.drain(); let outcome = await t.value
            precondition(outcome == .timedOut && f.receipts[0].deadline == 108)
            precondition(f.receipts[0].staleRetirementSeconds > 2 && f.prepareCount == 0 && f.restoreCount == 0)
            precondition(f.cache == nil && !f.held && f.renewal.stoppedCacheOwnership == .absent)
            precondition(f.renewal.resourcePhase == .refreshRequired && f.receipts[0].cleanupConfirmed)
            pass("stale retirement consumes original budget and cannot start native six-second work with insufficient time", f)
        }
        do {
            let f = Fixture(); f.makeDebt()
            f.retiringStale = { f.time += 1.25 }; f.prepared = { f.time += 5.5 }
            let t = await start(f); f.drain(); let outcome = await t.value
            precondition(outcome == .prepared && f.receipts[0].deadline == 108 && f.restorationDeadlines == [108])
            precondition(f.receipts[0].staleRetirementSeconds == 1.25 && f.receipts[0].preparationSeconds == 5.5)
            pass("old disposal new preparation and restore share one absolute eight-second deadline", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); f.quietSuccess = false
            f.retiringStale = { f.time = 109; f.fireTimers() }
            let t = await start(f); f.drain(); let outcome = await t.value
            precondition(outcome == .timedOut && f.renewal.resourcePhase == .quarantined && f.held && f.retainedOwner != nil)
            precondition(f.receipts[0].staleRetirementResult == 0 && !f.receipts[0].cleanupConfirmed)
            precondition(f.renewal.stoppedCacheOwnership == .absent && f.cache == nil)
            precondition(f.prepareCount == 0 && f.restoreCount == 0 && f.discardCount == 0)
            let blocked = await f.request(); precondition(blocked == .failed)
            pass("unconfirmed quiet after late stale retirement quarantines exact owner without forward work", f)
        }
        do {
            let f = Fixture(); f.makeDebt()
            f.context.inputOptedIn = true; f.context.inputAvailable = true; f.context.engineRunning = true
            let t = await start(f); f.drain(); let outcome = await t.value
            precondition(outcome == .skipped && f.context.inputAvailable && f.context.outputAvailable)
            precondition(f.cache == 1 && f.staleRetirementCount == 0 && f.prepareCount == 0)
            precondition(f.renewal.resourcePhase == .refreshRequired && f.renewal.stoppedCacheOwnership == .retained)
            f.context.inputOptedIn = false; f.context.inputAvailable = false
            f.context.outputAvailable = false; f.context.engineRunning = false; f.renewal.invalidate()
            let fresh = await start(f); f.drain(); let freshOutcome = await fresh.value
            precondition(freshOutcome == .prepared && f.staleRetirementCount == 1 && f.cache == 2)
            pass("ineligible restore preserves active input and stale ownership until a fresh stopped request can retire", f)
        }
        do {
            let f = Fixture(); f.makeDebt(); f.renewal.consume()
            f.context.inputOptedIn = true; f.context.inputAvailable = true; f.context.engineRunning = true
            f.context.captureClosed = false; f.context.captureState = 8
            precondition(f.renewal.resourcePhase == .consumed && f.renewal.stoppedCacheOwnership == .unconfirmed && f.cache == 1)
            let ordinary = await f.request(); precondition(ordinary == .notNeeded && f.queue.isEmpty)
            f.cache = nil; f.renewal.confirmShutdown()
            precondition(f.renewal.resourcePhase == .absent && f.renewal.stoppedCacheOwnership == .absent)
            pass("activation records consumed authority without falsely proving cache absence or renewing an active mic", f)
        }
        for result in [-7, 2] {
            let f = Fixture(); f.makeDebt(); f.staleRetirementResult = result
            let t = await start(f); f.drain(); let outcome = await t.value
            precondition(outcome == .cleanupUnconfirmed && f.renewal.resourcePhase == .quarantined && f.retainedOwner?.identity == 41)
            precondition(f.renewal.stoppedCacheOwnership == .unconfirmed && f.cache == 1 && f.held)
            precondition(f.receipts[0].staleRetirementResult == result && !f.receipts[0].cleanupConfirmed)
            precondition(f.prepareCount == 0 && f.restoreCount == 0 && f.discardCount == 0)
            pass("stale retirement status \(result) cannot certify absence and quarantines the retained owner", f)
        }
        // END DEFERRED RETIREMENT REGRESSIONS
        do {
            let f = Fixture(); f.makeDebt()
            f.onHold = { f.context.soundOn = false; f.renewal.invalidate() }
            let t = await start(f); f.drain(); let outcome = await t.value
            precondition(outcome == .superseded && f.cache == 1 && f.staleRetirementCount == 0 && f.prepareCount == 0)
            precondition(f.renewal.stoppedCacheOwnership == .retained && f.renewal.resourcePhase == .refreshRequired)
            precondition(f.receipts[0].cleanupConfirmed && f.receipts[0].retirementResult == nil && !f.held)
            pass("revocation before stale disposal preserves old ownership and cannot report false absence", f)
        }
        print("PASS \(count) actual production renewal orchestration scenarios; no SDK/hardware calls")
    }
}
