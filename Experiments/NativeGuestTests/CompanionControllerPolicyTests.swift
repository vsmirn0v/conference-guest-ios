import Foundation

private enum PolicyTestError: Error { case assertion(String) }
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw PolicyTestError.assertion(message) }
}

@MainActor private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor private final class Effects {
    let revision = CompanionControlRevision()
    var events: [String] = []
    var blocked: String?
    let gate = Gate()
    var permission = true
    func event(_ name: String) async {
        events.append(name)
        if blocked == name { await gate.wait() }
    }
    func apply(_ intent: CompanionMediaIntent, expected: UInt64) async throws {
        try await CompanionMediaPolicy.apply(intent, validate: { try self.revision.check(expected) },
            permitted: { _ in self.permission },
            authorize: { field in await self.event("authorize:\(field.rawValue)"); return true },
            activateMicrophone: { await self.event("activate") },
            mute: { muted, video in await self.event("\(video ? "camera" : "microphone"):\(muted ? "muted" : "on")") },
            setOutput: { await self.event("output:\($0)") })
    }
}

@main private struct CompanionControllerPolicyTests {
    @MainActor static func spin(_ predicate: () -> Bool) async throws {
        for _ in 0..<10_000 { if predicate() { return }; await Task.yield() }
        throw PolicyTestError.assertion("Controlled operation did not reach its gate")
    }
    @MainActor static func expectCancelled(_ task: Task<Void, Error>) async throws {
        do { try await task.value; throw PolicyTestError.assertion("Stale operation completed") }
        catch is CancellationError { }
    }
    @MainActor static func suspendedChanges() async throws {
        let stages = ["authorize:microphone", "authorize:camera", "activate", "microphone:on", "camera:on", "output:true"]
        for (index, stage) in stages.enumerated() {
            let effects = Effects(); effects.blocked = stage
            _ = effects.revision.advance()
            let original = effects.revision.current
            let task = Task { try await effects.apply(.init(microphoneOn: true, cameraOn: true, outputOn: true), expected: original) }
            try await spin { effects.gate.entered }
            _ = effects.revision.advance() // A newer local or IPC mute replaces this request.
            effects.gate.release()
            try await expectCancelled(task)
            try expect(effects.events == Array(stages.prefix(index + 1)), "No effect may follow stale completion at \(stage)")
            effects.blocked = nil
            try await effects.apply(.init(outputOn: false), expected: effects.revision.current)
            try expect(Array(effects.events.suffix(3)) == ["microphone:muted", "camera:muted", "output:false"],
                       "The latest mute/output intent must still apply after discarding stale work")
        }
    }
    @MainActor static func leaveDuringPermission() async throws {
        for stage in ["authorize:microphone", "authorize:camera"] {
            let effects = Effects(); effects.blocked = stage
            _ = effects.revision.advance()
            let original = effects.revision.current
            let task = Task { try await effects.apply(.init(microphoneOn: true, cameraOn: true, outputOn: true), expected: original) }
            try await spin { effects.gate.entered }
            effects.revision.stop()
            effects.gate.release()
            try await expectCancelled(task)
            try expect(!effects.events.contains("activate") && !effects.events.contains("microphone:on") && !effects.events.contains("camera:on"),
                       "Permission granted after Leave must never activate capture or send media")
            try expect(!effects.revision.advance(), "Leave cannot be reversed by a delayed control")
        }
    }
    @MainActor static func deniedRoomPermission() async throws {
        let effects = Effects(); effects.permission = false; _ = effects.revision.advance()
        do {
            try await effects.apply(.init(microphoneOn: true, outputOn: true), expected: effects.revision.current)
            throw PolicyTestError.assertion("Denied room permission was accepted")
        } catch CompanionMediaControlError.permissionDenied { }
        try expect(effects.events.isEmpty, "Room permission denial must precede TCC and device access")
    }
    @MainActor static func sharedShutdown() async throws {
        let shutdown = CompanionShutdown(), cleanup = Gate()
        var calls = 0, completed = 0
        let first = shutdown.start { calls += 1; await cleanup.wait() }
        let firstWaiter = Task { await first.value; completed += 1 }
        try await spin { cleanup.entered }
        let second = shutdown.start { calls += 100 }
        let secondWaiter = Task { await second.value; completed += 1 }
        for _ in 0..<20 { await Task.yield() }
        try expect(calls == 1 && completed == 0, "Repeated Quit must not bypass pending media cleanup")
        cleanup.release()
        await firstWaiter.value; await secondWaiter.value
        try expect(calls == 1 && completed == 2, "All shutdown callers join the same completed cleanup")
    }
    @MainActor static func statusPublicationOrdering() async throws {
        for suspendWrite in [false, true] {
            let publication = CompanionStatusPublication(), blocked = Gate()
            let metadata = NativeGuestMetadata(sessionID: UUID())
            var requests = 0, prepared = 0, activeWrites = 0, maxWriters = 0
            var records: [NativeGuestState] = []
            func publish(_ state: NativeGuestState? = nil) async {
                requests += 1
                await publication.publish(state: state, prepare: { terminal in
                    prepared += 1
                    if !suspendWrite && prepared == 1 { await blocked.wait() }
                    return NativeGuestStatus(metadata: metadata, state: terminal ?? .active,
                        microphoneOn: false, cameraOn: false, outputOn: true)
                }, write: { record in
                    activeWrites += 1; maxWriters = max(maxWriters, activeWrites)
                    if suspendWrite && records.isEmpty { await blocked.wait() }
                    records.append(record.state); activeWrites -= 1
                })
            }
            let old = Task { await publish() }
            try await spin { blocked.entered }
            let newer = Task { await publish() }
            let leave = Task { await publish(.left) }
            try await spin { requests == 3 }
            blocked.release()
            await old.value; await newer.value; await leave.value
            try expect(records == (suspendWrite ? [.active, .left] : [.left]),
                       "Old preparation is discarded; an already-started write precedes terminal state")
            await publish()
            try expect(records.last == .left && maxWriters == 1,
                       "Terminal state is retained and only one writer is allowed")
        }
    }
    static func maskedControls() throws {
        let metadata = NativeGuestMetadata(sessionID: UUID())
        let local = CompanionMediaIntent(microphoneOn: true, cameraOn: true, outputOn: true)
        var command = NativeGuestCommand(metadata: metadata, showWindowSequence: 1)
        try expect(local.merging(command) == local, "Show window cannot overwrite a pending local capture request")
        command.mediaFields = [.microphone]; command.microphoneOn = false
        let micOnly = local.merging(command)
        try expect(!micOnly.microphoneOn && micOnly.cameraOn && micOnly.outputOn, "Host mute preserves pending local camera/output intent")
        command.mediaFields = [.camera]; command.cameraOn = false
        let cameraOnly = local.merging(command)
        try expect(cameraOnly.microphoneOn && !cameraOnly.cameraOn && cameraOnly.outputOn, "Camera change preserves other controls")
        command.mediaFields = [.output]; command.outputOn = false
        let outputOnly = local.merging(command)
        try expect(outputOnly.microphoneOn && outputOnly.cameraOn && !outputOnly.outputOn, "Sound change preserves capture intent")
    }
    static func captureEvidence() throws {
        let valid: [String: Any] = ["inputRunning": true, "inputEnabled": true, "inputAvailable": true,
                                  "microphoneMuted": false, "snapshotUptime": 100.0]
        try expect(CompanionMediaPolicy.microphoneCapturing(valid, uptime: 105), "Fresh native evidence permits an active indicator")
        try expect(!CompanionMediaPolicy.microphoneCapturing(valid, uptime: 105.001), "Stale evidence is unknown")
        try expect(!CompanionMediaPolicy.microphoneCapturing(valid, uptime: 99), "Future evidence is rejected")
        try expect(!CompanionMediaPolicy.microphoneCapturing(nil, uptime: 100), "Missing evidence is unknown")
        for key in ["inputRunning", "inputEnabled", "inputAvailable", "microphoneMuted"] {
            var invalid = valid; invalid[key] = key == "microphoneMuted"
            try expect(!CompanionMediaPolicy.microphoneCapturing(invalid, uptime: 101), "\(key) must agree with capture")
        }
        let disabled: [String: Any] = ["inputAvailable": false, "inputEnabled": true,
            "microphoneOptIn": false, "microphoneMuted": true, "snapshotUptime": 100.0]
        try expect(CompanionMediaPolicy.captureDisabled(disabled, cameraAbsent: true, uptime: 101), "Fresh disabled input and absent camera")
        try expect(!CompanionMediaPolicy.captureDisabled(disabled, cameraAbsent: false, uptime: 101), "Camera presence rejects disabled evidence")
        for key in ["inputAvailable", "microphoneOptIn", "microphoneMuted"] {
            var invalid = disabled; invalid[key] = key != "microphoneMuted"
            try expect(!CompanionMediaPolicy.captureDisabled(invalid, cameraAbsent: true, uptime: 101), "\(key) must affirm the disabled input gate")
        }
        try expect(!CompanionMediaPolicy.captureDisabled(nil, cameraAbsent: true, uptime: 101), "Missing input evidence is unknown")
        try expect(!CompanionMediaPolicy.captureDisabled(disabled, cameraAbsent: true, uptime: 106), "Stale input evidence is unknown")
        try expect(CompanionMediaPolicy.isScreenShare("SCREEN_SHARE") && !CompanionMediaPolicy.isScreenShare("CAMERA"),
                   "Screen priority uses the provider's formal source value")
    }
    @MainActor static func main() async {
        do {
            try maskedControls(); try captureEvidence()
            try await suspendedChanges(); try await leaveDuringPermission()
            try await deniedRoomPermission(); try await sharedShutdown(); try await statusPublicationOrdering()
            print("PASS: companion control revisions, permission races, field masks, capture evidence, shared shutdown and status-publication races")
        } catch {
            fputs("FAIL: \(error)\n", stderr); exit(1)
        }
    }
}
