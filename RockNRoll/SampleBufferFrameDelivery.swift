import AVFoundation
import UIKit

/// Serializes enqueue/flush and rejects frames from retired video sources. On
/// iOS 17+ only the renderer is touched off-main, never its layer or UIView.
final class SampleBufferRenderTarget: @unchecked Sendable {
    private static var useLegacyForTesting: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["CONFERENCE_TEST_LEGACY_RENDERER"] == "1"
#else
        false
#endif
    }
    private final class Backing {
        let layer: AVSampleBufferDisplayLayer
        let imageRenderer: SampleBufferImageRenderer?
        let enqueue: (CMSampleBuffer) -> Bool
        let flush: (Bool, @escaping @Sendable () -> Void) -> Void
        let resetError: () -> Bool
        let status: () -> AVQueuedSampleBufferRenderingStatus
#if DEBUG
        let evidence: () -> [String: Any]
#endif
        @MainActor init(layer: AVSampleBufferDisplayLayer, imageRecovery: Bool = false,
                       onFrame: @escaping @MainActor () -> Void = {}) {
            // The renderer does not keep its display layer alive.
            self.layer = layer
            if imageRecovery {
                let image = SampleBufferImageRenderer(onFrame: onFrame)
                imageRenderer = image
                enqueue = { image.enqueue($0) }
                flush = { remove, completion in image.flush(removingImage: remove); completion() }
                resetError = { false }; status = { image.status }
#if DEBUG
                evidence = {
                    var values: [String: Any] = ["rendererStatus": image.status.rawValue, "imageRecovery": true,
                        "rendererResetError": false, "flushRequired": false]
                    values.merge(image.evidenceForTesting) { _, value in value }; return values
                }
#endif
                return
            }
            imageRenderer = nil
            if #available(iOS 17.0, *), !SampleBufferRenderTarget.useLegacyForTesting {
                let renderer = layer.sampleBufferRenderer
                resetError = { renderer.status == .failed && Self.isReset(renderer.error) }
                status = { renderer.status }
                enqueue = { sample in
                    guard renderer.status != .failed else { return false }
                    guard renderer.isReadyForMoreMediaData else { return false }
                    renderer.enqueue(sample); return renderer.status != .failed
                }
                flush = { renderer.flush(removingDisplayedImage: $0, completionHandler: $1) }
#if DEBUG
                evidence = {
                    var values: [String: Any] = ["rendererStatus": renderer.status.rawValue,
                    "rendererResetError": Self.isReset(renderer.error),
                    "ready": renderer.isReadyForMoreMediaData,
                    "flushRequired": renderer.requiresFlushToResumeDecoding]
                    if let error = renderer.error as NSError? {
                        values["errorDomain"] = error.domain; values["errorCode"] = error.code
                        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                            values["underlyingDomain"] = underlying.domain; values["underlyingCode"] = underlying.code
                        }
                    }
                    return values
                }
#endif
            } else {
                resetError = { precondition(Thread.isMainThread); return layer.status == .failed && Self.isReset(layer.error) }
                status = { precondition(Thread.isMainThread); return layer.status }
                enqueue = { sample in
                    precondition(Thread.isMainThread)
                    guard layer.status != .failed else { return false }
                    guard layer.isReadyForMoreMediaData else { return false }
                    layer.enqueue(sample); return layer.status != .failed
                }
                flush = { remove, completion in
                    precondition(Thread.isMainThread)
                    if remove { layer.flushAndRemoveImage() } else { layer.flush() }
                    completion()
                }
#if DEBUG
                evidence = { ["rendererStatus": layer.status.rawValue,
                    "rendererResetError": Self.isReset(layer.error),
                    "ready": layer.isReadyForMoreMediaData,
                    "flushRequired": layer.requiresFlushToResumeDecoding] }
#endif
            }
        }
        deinit {
            let layer = layer
            DispatchQueue.main.async { withExtendedLifetime(layer) {} }
        }
        static func isReset(_ error: Error?) -> Bool {
            guard let error = error as NSError? else { return false }
            return error.domain == AVFoundationErrorDomain && error.code == AVError.Code.mediaServicesWereReset.rawValue
        }
    }
    let supportsBackground: Bool
    private let lock = NSLock()
    private var backing: Backing
    private var generation = UUID()
    private var latest: (CMSampleBuffer, UUID)?
    private var pendingRepair: UUID?
    private var pendingRepairDeadline: TimeInterval = 0
    private var repairAttempts = 0
    private var flushedBacking: Backing?
    private var replayNeeded = false
    private var flushing: UUID?
    private var flushingRemovesImage = true
    private var removeAfterFlush = false
    private var flushDeadline: TimeInterval = 0
    @MainActor private var healthCheck: UUID?
    private var resetObserver: NSObjectProtocol?
    private enum FlushContinuation { case replay, remove(UUID) }
    private let replaced: @MainActor (AVSampleBufferDisplayLayer) -> Void
    private let recoveredFrame: @MainActor () -> Void
#if DEBUG
    private var attempts = 0, accepted = 0, rebuilds = 0, repairOperations = 0
    private var forcedReset = false
    private var beforeReplay: [String: Any] = [:], afterReplay: [String: Any] = [:]
    private var beforeFlush: [String: Any] = [:], afterFlush: [String: Any] = [:]
    @MainActor private var forcedLayerReset = false
    @MainActor private var forcedLayerStatus: AVQueuedSampleBufferRenderingStatus?
    func forceResetErrorForTesting(_ value: Bool) { lock.lock(); forcedReset = value; lock.unlock() }
    @MainActor func forceLayerHealthForTesting(reset: Bool, status: AVQueuedSampleBufferRenderingStatus?) {
        forcedLayerReset = reset; forcedLayerStatus = status
    }
    func holdLockForTesting(acquired: DispatchSemaphore, release: DispatchSemaphore) {
        lock.lock(); acquired.signal(); release.wait(); lock.unlock()
    }
    @MainActor func beginPendingFlushForTesting(timeout: TimeInterval = 12,
        completionDeadline: TimeInterval? = nil, startDeadline: TimeInterval? = nil) -> @MainActor () -> Void {
        lock.lock()
        let token = UUID(), expected = backing
        flushing = token; replayNeeded = true; flushDeadline = ProcessInfo.processInfo.systemUptime + timeout
        lock.unlock()
        if let startDeadline {
            DispatchQueue.main.async { [weak self, weak expected] in
                guard let expected else { return }
                self?.recoverBacking(token: token, expected: expected, deadline: startDeadline)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self, weak expected] in
            guard let expected else { return }
            self?.flushTimedOut(token: token, expected: expected, deadline: ProcessInfo.processInfo.systemUptime + 1)
        }
        return { [weak self] in
            self?.finishFlush(token: token, expected: expected,
                deadline: completionDeadline ?? ProcessInfo.processInfo.systemUptime + 12)
        }
    }
    func expireRepairForTesting() { lock.lock(); pendingRepairDeadline = 0; lock.unlock() }
    @MainActor func useImageRecoveryForTesting() -> SampleBufferImageRenderer {
        lock.lock()
        let next = Backing(layer: backing.layer, imageRecovery: true, onFrame: recoveredFrame)
        backing = next
        lock.unlock()
        replaced(next.layer)
        return next.imageRenderer!
    }
    @MainActor var evidenceForTesting: [String: Any] {
        guard lock.try() else { return ["busy": true] }
        defer { lock.unlock() }
        var evidence: [String: Any] = ["attempts": attempts, "accepted": accepted, "rebuilds": rebuilds,
            "status": backing.status().rawValue,
            "repairs": repairOperations, "budgetUsed": repairAttempts, "flushing": flushing != nil,
            "beforeFlush": beforeFlush, "afterFlush": afterFlush,
            "beforeReplay": beforeReplay, "afterReplay": afterReplay]
        evidence.merge(backing.evidence()) { _, value in value }
        return evidence
    }
#endif
    @MainActor var recoveryImageLayer: CALayer? {
        lock.lock(); defer { lock.unlock() }; return backing.imageRenderer?.layer
    }
    var isPresentationReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return backing.imageRenderer == nil || backing.status() == .rendering
    }
    @MainActor init(layer: AVSampleBufferDisplayLayer,
                    onLayerReplaced: @escaping @MainActor (AVSampleBufferDisplayLayer) -> Void = { _ in },
                    onRecoveredFrame: @escaping @MainActor () -> Void = {}) {
        backing = Backing(layer: layer); replaced = onLayerReplaced; recoveredFrame = onRecoveredFrame
        if #available(iOS 17.0, *), !Self.useLegacyForTesting { supportsBackground = true } else { supportsBackground = false }
        resetObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.mediaServicesReset() }
            }
    }
    deinit {
        if let resetObserver { NotificationCenter.default.removeObserver(resetObserver) }
        // Retired converters can release their last reference off-main.
        let backing = backing
        DispatchQueue.main.async { withExtendedLifetime(backing) {} }
    }
    func beginSource() -> UUID {
        lock.lock(); defer { lock.unlock() }
        backing.imageRenderer?.flush(removingImage: false)
        generation = UUID(); latest = nil; pendingRepair = nil; replayNeeded = false; return generation
    }
    func isCurrent(_ source: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }; return generation == source
    }
    @discardableResult func enqueue(_ sample: CMSampleBuffer, source: UUID? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard source == nil || source == generation else { return false }
        reapExpiredRepairLocked()
        latest = (sample, generation)
        if flushing != nil {
            replayNeeded = true
            if ProcessInfo.processInfo.systemUptime >= flushDeadline { scheduleRepairLocked() }
            return false
        }
        if hasResetErrorLocked() { scheduleRepairLocked(); return false }
        let result = backing.enqueue(sample)
        if result { replayNeeded = false }
#if DEBUG
        attempts += 1; if result { accepted += 1 }
#endif
        if backing.resetError() { scheduleRepairLocked() }
        return result
    }
    func invalidate(_ source: UUID) {
        lock.lock(); defer { lock.unlock() }
        if generation == source {
            generation = UUID(); latest = nil; pendingRepair = nil; replayNeeded = false
            backing.imageRenderer?.flush(removingImage: false)
        }
    }
    func clear(removingImage: Bool) {
        lock.lock()
        generation = UUID(); latest = nil; pendingRepair = nil; replayNeeded = false
        backing.imageRenderer?.flush(removingImage: false)
        let request = reserveFlushLocked(removingImage: removingImage)
        lock.unlock()
        startClearFlush(request)
    }
    func clearImage() {
        lock.lock(); latest = nil; pendingRepair = nil; replayNeeded = false
        backing.imageRenderer?.flush(removingImage: false)
        let request = reserveFlushLocked(removingImage: true)
        lock.unlock()
        startClearFlush(request)
    }
    private func reserveFlushLocked(removingImage: Bool) -> (UUID, Backing)? {
        if flushing != nil {
            if removingImage && !flushingRemovesImage { removeAfterFlush = true }
            return nil
        }
        let token = UUID()
        flushing = token; flushingRemovesImage = removingImage
        flushDeadline = ProcessInfo.processInfo.systemUptime + 12
        return (token, backing)
    }
    private func startClearFlush(_ request: (UUID, Backing)?) {
        guard let (token, expected) = request else { return }
        DispatchQueue.main.async { [weak self] in
            self?.scheduleFlush(token: token, expected: expected, delay: 0)
        }
    }
    private func hasResetErrorLocked() -> Bool {
#if DEBUG
        if forcedReset && backing.imageRenderer == nil { return true }
#endif
        return backing.status() == .failed
    }
    /// Check asynchronous failures after first geometry and backing installation.
    @MainActor func checkRecovery() {
        guard healthCheck == nil else { return }
        let token = UUID(); healthCheck = token
        checkRecovery(token: token, deadline: ProcessInfo.processInfo.systemUptime + 12)
    }
    @MainActor private func checkRecovery(token: UUID, deadline: TimeInterval) {
        guard healthCheck == token else { return }
        guard ProcessInfo.processInfo.systemUptime < deadline else { healthCheck = nil; return }
        guard lock.try() else { retryHealth(token: token, deadline: deadline); return }
        reapExpiredRepairLocked()
        var reset = hasResetErrorLocked()
        var status = backing.status()
#if DEBUG
        reset = reset || forcedLayerReset
        status = forcedLayerStatus ?? status
#endif
        var replayed = false, notifyReplay = false, retry = false
        if latest == nil || flushing != nil { healthCheck = nil }
        else if reset { scheduleRepairLocked(); healthCheck = nil }
        else {
            if replayNeeded, let latest, latest.1 == generation {
#if DEBUG
                beforeReplay = backing.evidence(); attempts += 1
#endif
                replayed = backing.enqueue(latest.0)
#if DEBUG
                afterReplay = backing.evidence(); if replayed { accepted += 1 }
#endif
                if replayed { replayNeeded = false }
                // Image conversion is asynchronous: its actual presentation
                // callback reveals the owner, never mere queue admission.
                notifyReplay = replayed && backing.imageRenderer == nil
            }
            // .unknown can precede an asynchronous layer-only reset error.
            retry = status != .rendering || replayNeeded
            if !retry {
                if pendingRepair == nil { repairAttempts = 0 }
                healthCheck = nil
            }
        }
        lock.unlock()
        if notifyReplay { recoveredFrame() }
        if retry { retryHealth(token: token, deadline: deadline) }
    }
    @MainActor private func retryHealth(token: UUID, deadline: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.checkRecovery(token: token, deadline: deadline)
        }
    }
    @MainActor private func mediaServicesReset(until deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 12) {
        guard lock.try() else {
            if ProcessInfo.processInfo.systemUptime < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.mediaServicesReset(until: deadline) }
            }
            return
        }
        defer { lock.unlock() }
        pendingRepair = nil; repairAttempts = 0
        if flushing == nil {
            flushedBacking = nil
            if latest != nil { scheduleRepairLocked() }
        }
    }
    private func scheduleRepairLocked() {
        guard pendingRepair == nil, backing.imageRenderer == nil else { return }
        let token = UUID(), expected = backing, deadline = ProcessInfo.processInfo.systemUptime + 12
        pendingRepair = token; pendingRepairDeadline = deadline
        let delay = 0.2 * pow(2, Double(repairAttempts))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.replaceBacking(token: token, expected: expected, deadline: deadline)
        }
    }
    private func reapExpiredRepairLocked() {
        if pendingRepair != nil, ProcessInfo.processInfo.systemUptime >= pendingRepairDeadline {
            pendingRepair = nil
        }
    }
    @MainActor private func replaceBacking(token: UUID, expected: Backing, deadline: TimeInterval) {
        guard lock.try() else {
            if ProcessInfo.processInfo.systemUptime < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.replaceBacking(token: token, expected: expected, deadline: deadline)
                }
            }
            return
        }
        guard pendingRepair == token, backing === expected else { lock.unlock(); return }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            pendingRepair = nil
            lock.unlock(); healthCheck = nil; checkRecovery(); return
        }
        if repairAttempts < 4 && flushedBacking !== expected && flushing == nil {
            pendingRepair = nil; repairAttempts += 1; flushedBacking = expected
#if DEBUG
            repairOperations += 1
#endif
            replayNeeded = true; flushing = token
            flushingRemovesImage = true
            flushDeadline = ProcessInfo.processInfo.systemUptime + 12
            lock.unlock()
            // Flush the attached failed connection before discarding it. New
            // renderers can inherit that connection's orphaned process state.
            scheduleFlush(token: token, expected: expected)
            return
        }
        lock.unlock()
        let imageRecovery = repairAttempts >= 4
        let next = Backing(layer: imageRecovery ? expected.layer : AVSampleBufferDisplayLayer(), imageRecovery: imageRecovery,
            onFrame: recoveredFrame)
        guard lock.try() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.replaceBacking(token: token, expected: expected, deadline: deadline)
            }
            return
        }
        guard pendingRepair == token, backing === expected else { lock.unlock(); return }
        backing = next; pendingRepair = nil; repairAttempts += 1; flushedBacking = next
        replayNeeded = true; flushing = token
        flushingRemovesImage = true; removeAfterFlush = false
        flushDeadline = ProcessInfo.processInfo.systemUptime + 12
#if DEBUG
        rebuilds += 1; repairOperations += 1
#endif
        lock.unlock()
        // Never call the view/delivery owner under the target lock. It can
        // reenter clear or retire a source while detaching its old layer.
        replaced(next.layer)
        // A fresh renderer can inherit the process's orphaned media connection.
        // Flushing immediately inside the reset/replacement turn leaves it
        // failed. Let notification delivery and layer attachment settle first;
        // the physical reset probe qualifies this 250 ms completion barrier.
        scheduleFlush(token: token, expected: next)
    }
    @MainActor private func scheduleFlush(token: UUID, expected: Backing, delay: TimeInterval = 0.25) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak expected] in
            guard let expected else { return }
            self?.recoverBacking(token: token, expected: expected,
                deadline: ProcessInfo.processInfo.systemUptime + 12)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self, weak expected] in
            guard let expected else { return }
            self?.flushTimedOut(token: token, expected: expected, deadline: ProcessInfo.processInfo.systemUptime + 1)
        }
    }
    @MainActor private func recoverBacking(token: UUID, expected: Backing, deadline: TimeInterval) {
        guard lock.try() else {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                // A valid start must survive suspension even on image recovery,
                // where replacing another AVFoundation layer cannot help.
                DispatchQueue.global(qos: .userInitiated).async { [weak self, weak expected] in
                    guard let self, let expected else { return }
                    self.lock.lock()
                    let current = self.flushing == token && self.backing === expected
                    self.lock.unlock()
                    guard current else { return }
                    DispatchQueue.main.async { [weak self] in
                        self?.recoverBacking(token: token, expected: expected,
                            deadline: ProcessInfo.processInfo.systemUptime + 12)
                    }
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak expected] in
                guard let expected else { return }
                self?.recoverBacking(token: token, expected: expected, deadline: deadline)
            }
            return
        }
        let current = flushing == token && backing === expected
        let removingImage = flushingRemovesImage
#if DEBUG
        if current {
            beforeFlush = expected.evidence()
            beforeFlush["appState"] = UIApplication.shared.applicationState.rawValue
        }
#endif
        lock.unlock()
        guard current else { return }
        expected.flush(removingImage) { [weak self, weak expected] in
            DispatchQueue.main.async {
                guard let expected else { return }
                self?.finishFlush(token: token, expected: expected,
                    deadline: ProcessInfo.processInfo.systemUptime + 12)
            }
        }
    }
    @MainActor private func finishFlush(token: UUID, expected: Backing, deadline: TimeInterval) {
        guard lock.try() else {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                // Preserve a completed barrier if bounded UI retries exhaust.
                // One state-only worker may wait for the lock; it never touches
                // UIKit or starts another native flush on this backing.
                DispatchQueue.global(qos: .userInitiated).async { [weak self, weak expected] in
                    guard let self, let expected else { return }
                    self.lock.lock()
                    let result = self.retireFlushLocked(token: token, expected: expected)
                    self.lock.unlock()
                    guard let result else { return }
                    DispatchQueue.main.async { [weak self] in
                        self?.resumeAfterFlush(result, expected: expected)
                    }
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.finishFlush(token: token, expected: expected, deadline: deadline)
            }
            return
        }
        guard flushing == token, backing === expected else { lock.unlock(); return }
#if DEBUG
        afterFlush = expected.evidence()
        afterFlush["appState"] = UIApplication.shared.applicationState.rawValue
#endif
        let result = retireFlushLocked(token: token, expected: expected)
        lock.unlock()
        if let result { resumeAfterFlush(result, expected: expected) }
    }
    /// State only. May be called by the durable completion cleanup worker.
    private func retireFlushLocked(token: UUID, expected: Backing) -> FlushContinuation? {
        guard flushing == token, backing === expected else { return nil }
        pendingRepair = nil
        if removeAfterFlush && !flushingRemovesImage {
            removeAfterFlush = false
            let next = UUID(); flushing = next; flushingRemovesImage = true
            flushDeadline = ProcessInfo.processInfo.systemUptime + 12
            return .remove(next)
        }
        flushing = nil; removeAfterFlush = false
        return .replay
    }
    @MainActor private func resumeAfterFlush(_ continuation: FlushContinuation, expected: Backing) {
        switch continuation {
        case .remove(let next): scheduleFlush(token: next, expected: expected, delay: 0)
        case .replay: healthCheck = nil; checkRecovery()
        }
    }
    @MainActor private func flushTimedOut(token: UUID, expected: Backing, deadline: TimeInterval) {
        guard lock.try() else {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.flushTimedOut(token: token, expected: expected, deadline: deadline)
            }
            return
        }
        defer { lock.unlock() }
        if flushing == token, backing === expected, latest != nil { scheduleRepairLocked() }
    }
}

/// Camera/decoded pixels arrive on the converter queue. Stable-size frames go
/// straight to AVFoundation; only changed geometry schedules a coalesced UI job.
/// The iOS 16 fallback keeps at most one newest sample awaiting the main thread.
final class SampleBufferFrameDelivery: @unchecked Sendable {
    private struct Geometry: Equatable { let size: CGSize; let rotation: Int }
    private let target: SampleBufferRenderTarget
    private let source: UUID
    private let background: Bool
    private let onGeometry: @MainActor (CGSize, Int) -> Void
    private let lock = NSLock()
    private var enabled = true
    private var retired = false
    private var active = false
    private var primed = false
    private var scheduled = false
    private var geometry: Geometry?
    private var submittedGeometry: Geometry?
    private var pending: (CMSampleBuffer?, Geometry)?
    #if DEBUG
    private var enqueueObserver: ((CMSampleBuffer, Bool) -> Void)?
    var onEnqueuedForTesting: ((CMSampleBuffer, Bool) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return enqueueObserver }
        set { lock.lock(); enqueueObserver = newValue; lock.unlock() }
    }
    #endif

    @MainActor init(target: SampleBufferRenderTarget, allowBackground: Bool = true,
                    onGeometry: @escaping @MainActor (CGSize, Int) -> Void) {
        self.target = target; source = target.beginSource()
        background = allowBackground && target.supportsBackground
        self.onGeometry = onGeometry
    }
    var isCurrent: Bool { lock.lock(); defer { lock.unlock() }; return !retired && target.isCurrent(source) }
    func setActive(_ value: Bool) { lock.lock(); active = value; lock.unlock() }
    func setEnabled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        if enabled != value {
            enabled = value; pending = nil; submittedGeometry = nil
            if value { primed = false; geometry = nil }
        }
    }
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        retired = true; pending = nil; submittedGeometry = nil; target.invalidate(source)
    }
    func deliver(_ sample: CMSampleBuffer, rotation: Int) {
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        let next = Geometry(size: CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels)), rotation: rotation)
        lock.lock(); defer { lock.unlock() }
        guard enabled, !retired, active || !primed, target.isCurrent(source) else { return }
        submittedGeometry = next
        if background {
            guard enqueue(sample), target.isPresentationReady else { return }
            primed = true
            guard geometry != next else { return }
            pending = (nil, next)
        } else { pending = (sample, next) }
        if !scheduled {
            scheduled = true
            DispatchQueue.main.async { [weak self] in self?.deliverGeometry() }
        }
    }
    private func enqueue(_ sample: CMSampleBuffer) -> Bool {
        let accepted = target.enqueue(sample, source: source)
        #if DEBUG
        enqueueObserver?(sample, accepted)
        #endif
        return accepted
    }
    /// A cached one-shot canvas has no producer callback after native recovery
    /// or asynchronous image conversion. Only its current owner may reveal it.
    @MainActor func recoveredFramePresented() {
        lock.lock()
        guard enabled, !retired, target.isCurrent(source), target.isPresentationReady,
              let submittedGeometry else { lock.unlock(); return }
        primed = true
        let changed = geometry != submittedGeometry
        geometry = submittedGeometry
        lock.unlock()
        if changed { onGeometry(submittedGeometry.size, submittedGeometry.rotation) }
    }
    @MainActor private func deliverGeometry() {
        lock.lock()
        scheduled = false
        let latest = pending; pending = nil
        guard enabled, !retired, target.isCurrent(source), let latest else { lock.unlock(); return }
        if let sample = latest.0 {
            guard active || !primed, enqueue(sample), target.isPresentationReady else { lock.unlock(); return }
            primed = true
        }
        let changed = geometry != latest.1
        geometry = latest.1
        lock.unlock()
        if changed { onGeometry(latest.1.size, latest.1.rotation) }
    }
}
