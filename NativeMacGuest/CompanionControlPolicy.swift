import Foundation

struct CompanionMediaIntent: Equatable {
    var microphoneOn = false
    var cameraOn = false
    var outputOn: Bool

    func merging(_ command: NativeGuestCommand) -> Self {
        var next = self
        if command.mediaFields.contains(.microphone) { next.microphoneOn = !command.held && command.microphoneOn }
        if command.mediaFields.contains(.camera) { next.cameraOn = !command.held && command.cameraOn }
        if command.mediaFields.contains(.output) { next.outputOn = !command.held && command.outputOn }
        return next
    }
}

enum CompanionMediaControlError: Error { case permissionDenied }

/// Invalidates suspended permission/device operations without waiting for them.
@MainActor final class CompanionControlRevision {
    private(set) var current: UInt64 = 0
    private(set) var stopped = false
    @discardableResult func advance() -> Bool {
        guard !stopped, current < UInt64.max else { return false }
        current += 1; return true
    }
    func stop() { stopped = true }
    func check(_ expected: UInt64) throws {
        try Task.checkCancellation()
        guard !stopped, current == expected else { throw CancellationError() }
    }
}

/// The real operation chain, with injected platform effects for deterministic race tests.
enum CompanionMediaPolicy {
    @MainActor static func apply(
        _ intent: CompanionMediaIntent, validate: () throws -> Void,
        permitted: (NativeGuestControlField) -> Bool,
        authorize: (NativeGuestControlField) async -> Bool,
        activateMicrophone: () async throws -> Void,
        mute: (_ muted: Bool, _ video: Bool) async throws -> Void,
        setOutput: (Bool) async throws -> Void
    ) async throws {
        try validate()
        for field in [NativeGuestControlField.microphone, .camera] {
            guard field == .microphone ? intent.microphoneOn : intent.cameraOn else { continue }
            guard permitted(field) else { throw CompanionMediaControlError.permissionDenied }
            let allowed = await authorize(field)
            try validate()
            guard allowed else { throw CompanionMediaControlError.permissionDenied }
        }
        if intent.microphoneOn {
            try await activateMicrophone()
            try validate()
        }
        try await mute(!intent.microphoneOn, false)
        try validate()
        try await mute(!intent.cameraOn, true)
        try validate()
        try await setOutput(intent.outputOn)
        try validate()
    }

    static func microphoneCapturing(_ snapshot: [String: Any]?, uptime: TimeInterval) -> Bool {
        guard let snapshot, let observed = snapshot["snapshotUptime"] as? TimeInterval,
              observed.isFinite, uptime.isFinite, uptime >= observed, uptime - observed <= 5 else { return false }
        return snapshot["inputRunning"] as? Bool == true && snapshot["inputEnabled"] as? Bool == true &&
            snapshot["inputAvailable"] as? Bool == true && snapshot["microphoneMuted"] as? Bool == false
    }

    static func captureDisabled(_ snapshot: [String: Any]?, cameraAbsent: Bool, uptime: TimeInterval) -> Bool {
        guard cameraAbsent, let snapshot, let observed = snapshot["snapshotUptime"] as? TimeInterval,
              observed.isFinite, uptime.isFinite, uptime >= observed, uptime - observed <= 5 else { return false }
        // Raw inputEnabled/inputRunning describe WebRTC demand. Native ADM's
        // effective input path is gated by availability before graph construction.
        return snapshot["inputAvailable"] as? Bool == false && snapshot["microphoneOptIn"] as? Bool == false &&
            snapshot["microphoneMuted"] as? Bool == true
    }

    /// SCREEN_SHARE is the provider's formal track-source value.
    static func isScreenShare(_ source: String?) -> Bool { source == "SCREEN_SHARE" }
}

/// Starting and observing shutdown are separate, so every caller joins exactly one task.
@MainActor final class CompanionShutdown {
    private(set) var task: Task<Void, Never>?
    func start(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        if let task { return task }
        let next = Task { @MainActor in await operation() }
        task = next
        return next
    }
}

/// One serialized writer; preparation that was superseded while suspended is discarded.
@MainActor final class CompanionStatusPublication {
    private var revision: UInt64 = 0
    private var pending = false
    private var task: Task<Void, Never>?
    private var terminal: NativeGuestState?
    func publish(state: NativeGuestState? = nil,
                 prepare: @escaping @MainActor (NativeGuestState?) async -> NativeGuestStatus,
                 write: @escaping @MainActor (NativeGuestStatus) async -> Void) async {
        revision &+= 1; pending = true
        if let state { terminal = state }
        if let task { await task.value; return }
        let next = Task { @MainActor [self] in
            while pending {
                pending = false
                let expected = revision
                let record = await prepare(terminal)
                guard expected == revision else { continue }
                await write(record)
            }
            task = nil
        }
        task = next
        await next.value
    }
}
