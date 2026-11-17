import AVFoundation
import ConferenceCore
import Foundation
import LiveKitWebRTC

enum NativeAdapterRecoveryPolicy {
    static func isRetryableTransportFailure(_ error: Error) -> Bool {
        if let error = error as? TelemostError { return error.isRetryable }
        if let error = error as? TrueConfError { return error.isRetryable }
        if error as? NativeDesktopRTCError == .cleanupFailed { return false }
        if error is URLError || error is NativeDesktopRTCError || error is GuestTransportError { return true }
        let system = error as NSError
        guard system.domain == NSPOSIXErrorDomain, let code = Int32(exactly: system.code) else { return false }
        switch POSIXErrorCode(rawValue: code) {
        case .ENOTCONN, .ECONNRESET, .ECONNABORTED, .EPIPE, .ETIMEDOUT,
             .ENETDOWN, .ENETRESET, .ENETUNREACH, .EHOSTUNREACH, .ECONNREFUSED: return true
        default: return false
        }
    }
}

/// Coordinates a single active connection generation and atomic peer retirement barrier
/// per external native adapter session. Cancellation of callers never cancels ownership cleanup.
@MainActor final class NativeAdapterRecoverySupervisor {
    let maximumRetries: Int
    private(set) var generation = UUID()
    private(set) var retries = 0
    private(set) var recoveryTask: Task<Void, Never>?
    private(set) var connectionRetirementTask: Task<Bool, Never>?
    private var connectionRetirementID: UUID?
    var cleanupSucceeded = true
    var failureDuringShutdown: String?
    #if DEBUG
    private(set) var connectionRetirementWaitersForTesting = 0
    #endif

    init(maximumRetries: Int = 3) {
        self.maximumRetries = maximumRetries
    }

    func resetForNewConnect() -> UUID {
        generation = UUID()
        retries = 0
        failureDuringShutdown = nil
        return generation
    }

    @discardableResult func advanceGeneration() -> UUID {
        generation = UUID()
        return generation
    }

    func cancelRecovery() {
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    func retireConnections(using work: @escaping @MainActor () async -> Bool) async -> Bool {
        if let connectionRetirementTask {
            #if DEBUG
            connectionRetirementWaitersForTesting += 1
            defer { connectionRetirementWaitersForTesting -= 1 }
            #endif
            return await connectionRetirementTask.value
        }
        let retirement = UUID()
        connectionRetirementID = retirement
        let task = Task { @MainActor [self] in
            let clean = await work()
            cleanupSucceeded = cleanupSucceeded && clean
            if clean, connectionRetirementID == retirement {
                connectionRetirementTask = nil
                connectionRetirementID = nil
            }
            return clean
        }
        connectionRetirementTask = task
        return await task.value
    }

    func scheduleRecovery(error: Error,
                          shouldIgnore: @MainActor () -> Bool,
                          onInterrupt: @MainActor (UUID) -> Void,
                          closeConnections: @escaping @MainActor () async -> Bool,
                          restart: @escaping @MainActor (UUID) async throws -> Void,
                          onTerminalFailure: @escaping @MainActor (Error) async -> Void,
                          onRetryFailure: @escaping @MainActor (UUID, Error) -> Void) {
        guard !shouldIgnore(), recoveryTask == nil else { return }
        guard NativeAdapterRecoveryPolicy.isRetryableTransportFailure(error), retries < maximumRetries else {
            let attempt = advanceGeneration()
            recoveryTask = Task { @MainActor [weak self] in
                guard let self, generation == attempt, !Task.isCancelled else { return }
                await onTerminalFailure(error)
            }
            return
        }
        retries += 1
        let attempt = advanceGeneration()
        onInterrupt(attempt)
        let retryCount = retries
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let clean = await closeConnections()
            guard generation == attempt, !Task.isCancelled else { return }
            guard clean else {
                await onTerminalFailure(NativeDesktopRTCError.cleanupFailed)
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(500 * retryCount))
                guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
                try await restart(attempt)
                guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
                recoveryTask = nil
            } catch {
                guard generation == attempt, !Task.isCancelled else { return }
                recoveryTask = nil
                onRetryFailure(attempt, error)
            }
        }
    }
}

@MainActor enum NativePeerOperations {
    static func makeEphemeralURLSession(delegate: URLSessionDelegate? = nil) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.httpShouldSetCookies = false
        if let delegate {
            return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        }
        return URLSession(configuration: config)
    }

    static func outboundVideoStatistics(from connection: LKRTCPeerConnection) async -> [[String: Any]] {
        let report = await withCheckedContinuation { continuation in
            connection.statistics { continuation.resume(returning: $0) }
        }
        return report.statistics.values.compactMap { row -> [String: Any]? in
            guard row.type == "outbound-rtp",
                  (row.values["kind"] ?? row.values["mediaType"]) as? String == "video" else { return nil }
            var value: [String: Any] = ["id": row.id]
            for field in ["bytesSent", "packetsSent", "framesEncoded", "framesSent", "frameWidth",
                          "frameHeight", "framesPerSecond", "mid", "mediaSourceId", "codecId",
                          "qpSum", "targetBitrate", "qualityLimitationReason"] {
                if let fieldValue = row.values[field] { value[field] = fieldValue }
            }
            if let id = row.values["codecId"] as? String, let codec = report.statistics[id] {
                value["codec"] = codec.values["mimeType"]
            }
            return value
        }
    }

    static func attachAudio(sharedAudio: SharedAudioEngine?,
                            profile: GuestAudioProfile,
                            quiet: Bool,
                            concurrent: Bool) async throws -> (any GuestMeetingAudio) {
        if let sharedAudio {
            let meeting = try await SharedGuestMeetingAudio.attach(to: sharedAudio)
            if Task.isCancelled {
                _ = await meeting.shutdown()
                throw CancellationError()
            }
            guard await meeting.beginAttempt(sound: !quiet) else {
                _ = await meeting.shutdown()
                throw NativeDesktopRTCError.cleanupFailed
            }
            return meeting
        }
#if DEBUG || NATIVE_LEGACY_AUDIO
        return try await GuestSystemAudio.create(microphoneEnabled: false, playoutEnabled: !quiet, profile: profile,
                                                 concurrent: concurrent)
#else
        throw NativeDesktopRTCError.cleanupFailed
#endif
    }
}

/// Only fields verified in the delivered Telemost client are emitted. Slot
/// indices stay stable across gallery reorder; a focused share preserves detail.
enum NativeDesktopSlotDemand {
    static func request(slots: [[String: Any]], visible: Set<String>?, focused: String?) -> [String: Any] {
        let count = max(8, min(49, slots.count))
        let sizes = (0..<count).map { index -> [String: Int] in
            let slot = slots.indices.contains(index) ? slots[index] : [:]
            let share = slot["participantScreenSharingByMid"] as? [String: Any]
            let camera = slot["participantVideoByMid"] as? [String: Any]
            let owner = (share ?? camera)?["participantId"] as? String
            if let focused, owner == focused, share != nil { return ["width": 3840, "height": 2160] }
            if let owner, visible?.contains(owner) == false { return ["width": 160, "height": 90] }
            return ["width": 1280, "height": 720]
        }
        return ["audioSlotsCount": 0, "slots": sizes, "gridConfig": [:],
            "withSelfView": false, "shutdownAllVideo": visible?.isEmpty == true]
    }
}
