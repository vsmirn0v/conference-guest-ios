import Foundation
import LiveKitWebRTC

enum GuestNativeCallError: Error, Equatable { case timedOut(String) }

public enum GuestMicrophoneTrackObservation: String, Sendable {
    case enabled, disabled, unavailable
    case noTrack = "no-track"
}

/// One read of the underlying track flag, with no track or participant IDs in its result.
@MainActor public struct GuestMicrophoneTrackProbe {
    public typealias Completion = @Sendable (GuestMicrophoneTrackObservation, TimeInterval) -> Void
    public enum Queue { case nativePeer, rockSDK }

    public var queue: Queue = .nativePeer
    public let isCurrent: () -> Bool
    public let start: (DispatchTime, @escaping Completion) -> Void

    public init(queue: Queue = .nativePeer, isCurrent: @escaping () -> Bool, start: @escaping (DispatchTime, @escaping Completion) -> Void) {
        self.queue = queue; self.isCurrent = isCurrent; self.start = start
    }

    public func checking(_ check: @escaping () -> Bool) -> Self {
        Self(queue: queue, isCurrent: { check() && isCurrent() }, start: start)
    }
}

/// Every call from Swift into one peer's native WebRTC objects runs here, in the
/// order it was made, and never on the main thread.
///
/// Most WebRTC Objective-C calls block their caller until WebRTC's signaling or
/// worker thread runs them. When the audio module is stuck in CoreAudio (e.g. for
/// 30 s after AirPods disappear), those threads wait for it, and a main-thread
/// caller froze the whole app. Here the caller only awaits: after `timeout` it
/// gets `GuestNativeCallError.timedOut` and the app stays responsive, while the
/// native call still completes later in order (a later call cannot overtake it).
public final class GuestNativeCalls: @unchecked Sendable {
    public let label: String
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending = 0
    private var timedOut = 0

    public init(label: String) {
        self.label = label
        queue = DispatchQueue(label: "guest.native.\(label)", qos: .userInitiated)
    }

    /// Calls that are queued or running, and how many callers gave up waiting.
    var evidence: (pending: Int, timedOut: Int) { lock.lock(); defer { lock.unlock() }; return (pending, timedOut) }

    /// Runs `body` on the native queue and waits for its result without blocking.
    func run<T>(_ name: String, timeout: TimeInterval = 8, _ body: @escaping () throws -> T) async throws -> T {
        try await call(name, timeout: timeout) { done in done(Result { try body() }) }
    }

    /// For native APIs that answer through a completion handler (offer, stats, ...):
    /// `start` runs on the native queue; `done` may be called from any thread.
    func call<T>(_ name: String, timeout: TimeInterval = 10,
                 _ start: @escaping (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try Task.checkCancellation()
        let completion = GuestCompletion<T>()
#if DEBUG
        let timeout = timeoutOverrideForTesting ?? timeout
#endif
        begin()
        let finish: (Result<T, Error>) -> Void = { result in completion.finish(result) }
        do {
            return try await withTaskCancellationHandler(operation: {
                return try await withCheckedThrowingContinuation { continuation in
                    completion.install(continuation, timeout: timeout)
                    queue.async { [self] in
                        start { result in finish(result) }
                        end()
                    }
                }
            }, onCancel: { completion.finish(.failure(CancellationError())) })
        } catch GuestTransportError.timedOut {
            recordTimeout(name, timeout: timeout)
            throw GuestNativeCallError.timedOut(name)
        }
    }

    /// Fire and forget, still in order with the awaited calls.
    func post(_ name: String, _ body: @escaping () -> Void) {
        begin()
        queue.async { [self] in body(); end() }
    }

    @MainActor func microphoneTrackProbe(_ track: LKRTCAudioTrack?,
                                         isCurrent: @escaping () -> Bool) -> GuestMicrophoneTrackProbe {
        let hadTrack = track != nil
        return GuestMicrophoneTrackProbe(isCurrent: isCurrent) { [weak track] deadline, finish in
            guard hadTrack else {
                finish(.noTrack, ProcessInfo.processInfo.systemUptime)
                return
            }
            self.post("diagnostic-microphone-track") { [weak track] in
                let state: GuestMicrophoneTrackObservation
                if DispatchTime.now() < deadline, let track { state = track.isEnabled ? .enabled : .disabled }
                else { state = .unavailable }
                finish(state, ProcessInfo.processInfo.systemUptime)
            }
        }
    }

#if DEBUG
    /// Shortens every wait in tests.
    var timeoutOverrideForTesting: TimeInterval?
    /// Blocks the native queue until `release` is called, as a stuck WebRTC thread would.
    func blockForTesting() -> () -> Void {
        let gate = DispatchSemaphore(value: 0)
        post("blocked-for-testing") { gate.wait() }
        return { gate.signal() }
    }
#endif

    private func begin() { lock.lock(); pending += 1; lock.unlock() }
    private func end() { lock.lock(); pending -= 1; lock.unlock() }
    private func recordTimeout(_ name: String, timeout: TimeInterval) {
        lock.lock(); timedOut += 1; let queued = pending; lock.unlock()
        probeLog("native-call-timeout", ["peer": label, "call": name, "timeoutSeconds": timeout, "queued": queued])
    }
}
