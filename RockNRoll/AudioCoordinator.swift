import AVFoundation
import Combine
import Foundation
import UIKit

/// Observes iOS media changes without competing with the provider for transport ownership.
@MainActor
final class AudioCoordinator {
    var onStatus: ((String?) -> Void)?
    var onInterruptionChanged: ((Bool) -> Void)?
    var onRouteChanged: (() -> Void)?
    var onServicesChanged: ((Bool) -> Void)?
    private let worker: AudioSessionWorker
    private let prepareSession: @Sendable () throws -> Void
    private let prepareInitialSession: @Sendable () throws -> Void
    private var needsInitialPreparation = true
    private let restoreMixingSession: @Sendable () throws -> Void
    private let recoveryWindow: Duration
    private let recoveryInterval: Duration
    private let notifications: NotificationCenter
    private var lease = AudioSessionLease()
    private var observingSession = false
    private var mixingTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var startupReady: (@MainActor () async throws -> Void)?
    private var startupFailure: (@MainActor (Error) -> Void)?
    private var servicesNeedRecovery = false
    private var mixingRevision = 0
    private var configurationLease: AudioSessionLease? = AudioSessionLease()
    private var routeLease: AudioSessionLease?
    private var outputRecovery = BuiltInOutputRecovery()
    private var outputRecoveryTask: Task<Void, Never>?
    private var outputRecoveryRevision = 0
    private var observers: [NSObjectProtocol] = []
    private struct RouteSnapshot: Sendable {
        let outputName: String
        let builtInSpeaker: Bool?
        let needsMixingRestore: Bool
        let debugSummary: String
    }

    private final class SnapshotBox: @unchecked Sendable {
        var value: RouteSnapshot?
        var changed = false
    }

    private var cachedOutputName: String = L("Audio output")
    private var cachedBuiltInSpeaker: Bool?
    private var routeSnapshotRevision = 0
    private var audioWarning: String?
    private var cameraWarning: String?

    var outputName: String { cachedOutputName }

    init(worker: AudioSessionWorker = .shared,
         prepareSession: (@Sendable () throws -> Void)? = nil,
         prepareInitialSession: (@Sendable () throws -> Void)? = nil,
         restoreMixingSession: @escaping @Sendable () throws -> Void = AudioCoordinator.restoreMixing,
         recoveryWindow: Duration = .seconds(12), recoveryInterval: Duration = .milliseconds(500),
         notifications: NotificationCenter = .default) {
        self.worker = worker
        self.prepareSession = prepareSession ?? { try Self.prepareCommunicationSession() }
        self.prepareInitialSession = prepareInitialSession ?? prepareSession ?? { try Self.prepareCommunicationSession(resetBuiltInRoute: true) }
        self.restoreMixingSession = restoreMixingSession
        self.recoveryWindow = recoveryWindow; self.recoveryInterval = recoveryInterval
        self.notifications = notifications
        let center = notifications
        for name in [AVAudioSession.interruptionNotification,
                     AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereLostNotification,
                     AVAudioSession.mediaServicesWereResetNotification,
                     UIApplication.didBecomeActiveNotification,
                     AVCaptureSession.wasInterruptedNotification,
                     AVCaptureSession.interruptionEndedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.handle(note) }
            })
        }
    }

    deinit {
        lease.invalidate(); configurationLease?.invalidate(); routeLease?.invalidate()
        mixingTask?.cancel(); resetTask?.cancel(); startupTask?.cancel(); outputRecoveryTask?.cancel()
        observers.forEach(notifications.removeObserver)
    }

    func beginSession() {
        endSession()
        lease = AudioSessionLease(); configurationLease = AudioSessionLease(); observingSession = true
    }
    func endSession() {
        observingSession = false; lease.invalidate()
        needsInitialPreparation = true
        servicesNeedRecovery = false
        cancelOutputRestoration()
        outputRecovery = BuiltInOutputRecovery()
        mixingTask?.cancel(); mixingTask = nil
        resetTask?.cancel(); resetTask = nil
        startupTask?.cancel(); startupTask = nil
        startupReady = nil; startupFailure = nil
        suspendConfiguration()
    }

    /// Transport replacement must not reset the selected built-in output.
    func preserveOutputForReconnect() {
        cancelOutputRestoration(preservingIntent: true)
        outputRecovery.beginInterruption()
    }

    /// Preserve the pre-call route rather than the temporary Phone route.
    func preserveOutputForInterruption() {
        preserveOutputForReconnect()
        suspendConfiguration()
    }

    /// Restore a built-in route once the replacement media transport is ready.
    /// Headsets selected during the competing call remain authoritative.
    func restoreOutputAfterInterruption() {
        guard let speaker = outputRecovery.takeRestore(currentSpeaker: currentBuiltInSpeaker) else { return }
        let expected = lease, revision = outputRecoveryRevision
        outputRecoveryTask = Task { [weak self] in
            guard let self, self.lease === expected, expected.isActive else { return }
            defer {
                if self.lease === expected, self.outputRecoveryRevision == revision {
                    self.outputRecovery.finishRestoration(currentSpeaker: self.currentBuiltInSpeaker)
                    self.outputRecoveryTask = nil
                }
            }
            // SDK initialization can reconfigure the session again after media
            // connects. Protect the route through that short, bounded window.
            for delay in [0, 250, 500, 1_000, 2_000] {
                do {
                    if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
                    guard self.lease === expected, expected.isActive,
                          self.outputRecoveryRevision == revision,
                          self.currentBuiltInSpeaker != nil else { return }
                    try await self.applyBuiltInOutput(speaker: speaker, preservingExternalRoute: true, onlyIfDifferent: true)
                    guard self.currentBuiltInSpeaker != nil else { return }
                } catch is CancellationError { return }
                catch {
                    #if DEBUG
                    print("Cannot restore pre-call audio output: \(error)")
                    #endif
                    return
                }
            }
        }
    }

    /// Explicit route selection takes precedence over automatic call recovery.
    func userWillSelectOutput() {
        cancelOutputRestoration()
        outputRecovery.cancelForUserSelection(currentSpeaker: currentBuiltInSpeaker)
    }

    private func cancelOutputRestoration(preservingIntent: Bool = false) {
        outputRecoveryRevision &+= 1
        outputRecoveryTask?.cancel(); outputRecoveryTask = nil
        routeLease?.invalidate(); routeLease = nil
        outputRecovery.finishRestoration(currentSpeaker: currentBuiltInSpeaker, preservingIntent: preservingIntent)
    }

    private var currentBuiltInSpeaker: Bool? {
        cachedBuiltInSpeaker
    }

    private func applyRouteSnapshot(_ snapshot: RouteSnapshot) {
        cachedOutputName = snapshot.outputName
        cachedBuiltInSpeaker = snapshot.builtInSpeaker
    }

    private func refreshRouteSnapshot(notify: Bool, after: (@MainActor () -> Void)? = nil) {
        let expected = lease
        routeSnapshotRevision &+= 1
        let revision = routeSnapshotRevision
        let box = SnapshotBox()
        worker.enqueue(lease: expected, operation: {
            box.value = Self.inspectRouteSnapshot()
        }) { [weak self] result in
            guard case .success = result, let snapshot = box.value else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.observingSession,
                      self.lease === expected,
                      expected.isActive,
                      self.routeSnapshotRevision == revision else { return }
                let previousName = self.cachedOutputName
                self.applyRouteSnapshot(snapshot)
                #if DEBUG
                print("Audio route types: \(snapshot.debugSummary)")
                #endif
                after?()
                if notify && self.cachedOutputName != previousName {
                    self.onRouteChanged?()
                }
            }
        }
    }

    private nonisolated static func inspectRouteSnapshot(_ session: AVAudioSession = AVAudioSession.sharedInstance()) -> RouteSnapshot {
        let outputs = session.currentRoute.outputs
        let inputs = session.currentRoute.inputs
        let outputName: String
        if let first = outputs.first {
            switch first.portType {
            case .builtInSpeaker: outputName = L("Speaker")
            case .builtInReceiver: outputName = L("iPhone receiver")
            default: outputName = first.portName
            }
        } else {
            outputName = L("Audio output")
        }
        let speaker = builtInSpeaker(session)
        let needsMixing = session.category == .playAndRecord && !session.categoryOptions.contains(.mixWithOthers)
        let summary = "input=[\(inputs.map { $0.portType.rawValue }.joined(separator: ","))] output=[\(outputs.map { $0.portType.rawValue }.joined(separator: ","))]"
        return RouteSnapshot(outputName: outputName, builtInSpeaker: speaker, needsMixingRestore: needsMixing, debugSummary: summary)
    }

    private nonisolated static func builtInSpeaker(_ session: AVAudioSession) -> Bool? {
        switch session.currentRoute.outputs.first?.portType {
        case .builtInSpeaker: return true
        case .builtInReceiver: return false
        default: return nil
        }
    }

    /// Hold retires optional category/route work without retiring the meeting.
    func suspendConfiguration() {
        configurationLease?.invalidate(); configurationLease = nil
        routeLease?.invalidate(); routeLease = nil
        mixingTask?.cancel(); mixingTask = nil
    }

    func start(preserveCurrentRoute: Bool = false, ready: @escaping @MainActor () async throws -> Void,
               failure: @escaping @MainActor (Error) -> Void) {
        beginSession()
        startupReady = ready; startupFailure = failure
        let expected = lease
        startupTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.prepareForJoin(preserveCurrentRoute: preserveCurrentRoute)
                guard self.lease === expected, expected.isActive else { return }
                try await ready()
                if self.lease === expected { self.startupReady = nil; self.startupFailure = nil }
            } catch is CancellationError { }
            catch { if self.lease === expected, expected.isActive { failure(error) } }
            if self.lease === expected { self.startupTask = nil }
        }
    }

    /// The provider may reconfigure the shared session later; real-device validation is required.
    func prepareForJoin(preserveCurrentRoute: Bool = false) async throws {
        let expected = lease
        let prepare = preserveCurrentRoute && needsInitialPreparation ? Self.prepareListeningSession :
            needsInitialPreparation ? prepareInitialSession : prepareSession
        let box = SnapshotBox()
        try await worker.perform(lease: expected) {
            try prepare()
            box.value = Self.inspectRouteSnapshot()
        }
        guard lease === expected, expected.isActive else { throw CancellationError() }
        needsInitialPreparation = false
        observingSession = true
        if let snapshot = box.value {
            applyRouteSnapshot(snapshot)
        }
        // The call owner activates the session before the SDK starts media.
        audioWarning = nil
        cameraWarning = nil
        publishStatus()
    }

    /// Video-chat mode implies a speaker default. Clearing a port override alone
    /// cannot select the receiver, so choose the matching communication mode too.
    func selectBuiltInOutput(speaker: Bool) async throws {
        userWillSelectOutput()
        try await applyBuiltInOutput(speaker: speaker)
        outputRecovery.observe(currentSpeaker: currentBuiltInSpeaker)
    }

    private func applyBuiltInOutput(speaker: Bool, preservingExternalRoute: Bool = false, onlyIfDifferent: Bool = false) async throws {
        guard let configuration = configurationLease, configuration.isActive else { throw CancellationError() }
        let expected = lease
        routeLease?.invalidate()
        let request = AudioSessionLease(); routeLease = request
        let box = SnapshotBox()
        try await worker.perform(lease: request) {
            try expected.check(); try configuration.check()
            let session = AVAudioSession.sharedInstance()
            let currentSpeaker = Self.builtInSpeaker(session)
            if preservingExternalRoute && currentSpeaker == nil {
                box.value = Self.inspectRouteSnapshot(session)
                return
            }
            if onlyIfDifferent && currentSpeaker == speaker {
                box.value = Self.inspectRouteSnapshot(session)
                return
            }
            var options = session.categoryOptions
            if !speaker { options.remove(.defaultToSpeaker) }
            let mode: AVAudioSession.Mode = [.voiceChat, .videoChat].contains(session.mode)
                ? (speaker ? .videoChat : .voiceChat) : session.mode
            if session.mode != mode || session.categoryOptions != options {
                try session.setCategory(session.category, mode: mode, options: options)
            }
            try expected.check(); try request.check(); try configuration.check()
            if preservingExternalRoute && Self.builtInSpeaker(session) == nil {
                box.value = Self.inspectRouteSnapshot(session)
                return
            }
            if let input = session.availableInputs?.first(where: { $0.portType == .builtInMic }), session.preferredInput != input {
                try session.setPreferredInput(input)
            }
            try expected.check(); try request.check(); try configuration.check()
            try session.overrideOutputAudioPort(speaker ? .speaker : .none)
            box.changed = true
            box.value = Self.inspectRouteSnapshot(session)
        }
        guard lease === expected, expected.isActive, routeLease === request else { throw CancellationError() }
        let previousName = cachedOutputName
        if let snapshot = box.value {
            applyRouteSnapshot(snapshot)
        }
        if box.changed || cachedOutputName != previousName {
            onRouteChanged?()
        }
    }

    /// The SDK changes the shared session after join; restore coexistence without
    /// replacing its selected voice-chat mode or route options.
    func ensureMixing() {
        guard lease.isActive, let configuration = configurationLease, configuration.isActive else { return }
        mixingRevision &+= 1
        guard mixingTask == nil else { return }
        let expected = lease
        let restore = restoreMixingSession
        mixingTask = Task { [weak self, worker] in
            guard let self else { return }
            defer { if self.lease === expected, self.configurationLease === configuration { self.mixingTask = nil } }
            while self.lease === expected, expected.isActive, configuration.isActive, !Task.isCancelled {
                let revision = self.mixingRevision
                do { try await worker.perform(lease: configuration) { try expected.check(); try restore() } }
                catch is CancellationError { return }
                catch {
                    guard self.lease === expected, expected.isActive else { return }
                    self.audioWarning = L("Cannot mix jam audio with other apps"); self.publishStatus(); return
                }
                if self.mixingRevision == revision { return }
            }
        }
    }

    nonisolated static var communicationOptions: AVAudioSession.CategoryOptions {
        [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP]
    }

    /// Background listening retains a receiver/speaker selection as well as an external route.
    private nonisolated static func prepareListeningSession() throws {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map(\.portType)
        let receiver = outputs.contains(.builtInReceiver)
        let speaker = outputs.contains(.builtInSpeaker)
        try session.setCategory(.playAndRecord, mode: receiver ? .voiceChat : .videoChat, options: communicationOptions)
        if receiver || speaker { try session.overrideOutputAudioPort(speaker ? .speaker : .none) }
        if session.preferredSampleRate != 48_000 { try? session.setPreferredSampleRate(48_000) }
    }

    private nonisolated static func prepareCommunicationSession(resetBuiltInRoute: Bool = false) throws {
        let session = AVAudioSession.sharedInstance(), options = communicationOptions
        if session.category != .playAndRecord || session.mode != .videoChat || session.categoryOptions != options {
            try session.setCategory(.playAndRecord, mode: .videoChat, options: options)
        }
        if resetBuiltInRoute {
            // A built-in choice belongs to its meeting. Release its pins before
            // fresh activation so the system can keep the selected headset.
            // Recovery retains the current meeting's explicit route instead.
            if session.preferredInput?.portType == .builtInMic { try session.setPreferredInput(nil) }
            try session.overrideOutputAudioPort(.none)
        }
        // A preference, not a forced hardware format: narrow-band Bluetooth
        // routes retain their supported rate and the native device resamples.
        if session.preferredSampleRate != 48_000 { try? session.setPreferredSampleRate(48_000) }
    }

    private nonisolated static func restoreMixing() throws {
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playAndRecord, !session.categoryOptions.contains(.mixWithOthers) else { return }
        try session.setCategory(session.category, mode: session.mode, options: session.categoryOptions.union(.mixWithOthers))
    }

    /// A new audio activation supersedes an earlier interruption warning.
    func callAudioDidActivate() {
        guard observingSession, lease.isActive else { return }
        if configurationLease == nil { configurationLease = AudioSessionLease() }
        audioWarning = nil
        ensureMixing()
        refreshRouteSnapshot(notify: true) { [weak self] in
            guard let self else { return }
            self.outputRecovery.observe(currentSpeaker: self.currentBuiltInSpeaker)
        }
        publishStatus()
    }

    /// iOS can deliver an interruption-began notification after CallKit has
    /// returned an active call session, without a matching ended notification.
    /// Reactivate only once the call owner confirms there is no competing call.
    func reactivateAfterInterruption() async throws {
        let expected = lease
        let restore = restoreMixingSession
        let box = SnapshotBox()
        try await worker.perform(lease: expected) {
            try AVAudioSession.sharedInstance().setActive(true)
            try expected.check(); try restore()
            box.value = Self.inspectRouteSnapshot()
        }
        guard lease === expected, expected.isActive else { throw CancellationError() }
        audioWarning = nil
        if let snapshot = box.value {
            let previousName = cachedOutputName
            applyRouteSnapshot(snapshot)
            #if DEBUG
            print("Audio route types: \(snapshot.debugSummary)")
            #endif
            if cachedOutputName != previousName { onRouteChanged?() }
        }
        publishStatus()
    }

    private func handle(_ notification: Notification) {
        guard observingSession else { return }
        switch notification.name {
        case AVAudioSession.interruptionNotification:
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            if type == .began {
                preserveOutputForInterruption()
                audioWarning = L("Audio interrupted by iOS")
                onInterruptionChanged?(true)
            } else if type == .ended {
                let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                audioWarning = options.contains(.shouldResume)
                    ? nil : L("Audio is paused by iOS; check the call audio")
                onInterruptionChanged?(false)
            }
        case AVAudioSession.mediaServicesWereLostNotification:
            servicesNeedRecovery = true
            lease.invalidate(); suspendConfiguration()
            audioWarning = L("Audio service unavailable")
            onServicesChanged?(false)
            onInterruptionChanged?(true)
        case AVAudioSession.mediaServicesWereResetNotification:
            recoverServices()
        case UIApplication.didBecomeActiveNotification:
            if servicesNeedRecovery && resetTask == nil { recoverServices() }
        case AVCaptureSession.wasInterruptedNotification:
            cameraWarning = L("Camera paused by iOS")
        case AVCaptureSession.interruptionEndedNotification:
            cameraWarning = nil
        case AVAudioSession.routeChangeNotification:
            // Ignore Phone's temporary built-in route while an interruption is active.
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = rawReason.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            let expected = lease
            routeSnapshotRevision &+= 1
            let revision = routeSnapshotRevision
            let box = SnapshotBox()
            worker.enqueue(lease: expected, operation: {
                box.value = Self.inspectRouteSnapshot()
            }) { [weak self] result in
                guard case .success = result, let snapshot = box.value else { return }
                Task { @MainActor [weak self] in
                    guard let self,
                          self.observingSession,
                          self.lease === expected,
                          expected.isActive,
                          self.routeSnapshotRevision == revision else { return }
                    self.applyRouteSnapshot(snapshot)
                    #if DEBUG
                    print("Audio route types: \(snapshot.debugSummary)")
                    #endif
                    if self.currentBuiltInSpeaker == nil { self.cancelOutputRestoration() }
                    if reason != .categoryChange && reason != .routeConfigurationChange {
                        self.outputRecovery.observe(currentSpeaker: self.currentBuiltInSpeaker)
                    }
                    if snapshot.needsMixingRestore {
                        self.ensureMixing()
                    }
                    self.onRouteChanged?()
                }
            }
        default:
            break
        }
        publishStatus()
    }

    private func recoverServices() {
        servicesNeedRecovery = true
        lease.invalidate(); lease = AudioSessionLease()
        mixingTask?.cancel(); mixingTask = nil; resetTask?.cancel()
        suspendConfiguration()
        startupTask?.cancel(); startupTask = nil
        let expected = lease
        audioWarning = L("Audio service unavailable")
        // A reset can arrive without a preceding lost notification.
        onServicesChanged?(false); onInterruptionChanged?(true)
        resetTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.lease === expected { self.resetTask = nil } }
            let deadline = ContinuousClock.now.advanced(by: self.recoveryWindow)
            var prepared = false
            while !Task.isCancelled, self.lease === expected, expected.isActive {
                do {
                    try await self.prepareForJoin()
                    guard self.lease === expected, expected.isActive else { return }
                    prepared = true; break
                } catch is CancellationError { return }
                catch {
                    guard self.lease === expected, expected.isActive, !Task.isCancelled else { return }
                    #if DEBUG
                    let failure = error as NSError
                    print("Audio service reconfiguration retry: \(failure.domain) code=\(failure.code)")
                    #endif
                    // The reset notification can precede usable category/route
                    // services. A transient failure must not strand this owner.
                    if ContinuousClock.now >= deadline {
                        self.audioWarning = L("Audio could not resume: %@", error.localizedDescription); self.publishStatus()
                        self.startupFailure?(error)
                        return
                    }
                    do { try await Task.sleep(for: self.recoveryInterval) } catch { return }
                }
            }
            guard prepared, !Task.isCancelled, self.lease === expected, expected.isActive else { return }
            do {
                if let ready = self.startupReady {
                    try await ready()
                    guard self.lease === expected, expected.isActive else { return }
                    self.startupReady = nil; self.startupFailure = nil
                }
                self.servicesNeedRecovery = false
                self.onServicesChanged?(true)
                self.onInterruptionChanged?(false)
            } catch is CancellationError { }
            catch {
                guard self.lease === expected, expected.isActive else { return }
                self.startupFailure?(error)
            }
        }
    }

    private func publishStatus() {
        onStatus?(audioWarning ?? cameraWarning)
    }
}

/// Stores only built-in output intent. A new external route wins over restoration.
struct BuiltInOutputRecovery {
    private var lastSpeaker: Bool?
    private var interrupted = false
    private var restoring = false
    mutating func observe(currentSpeaker: Bool?) {
        if !interrupted && !restoring { lastSpeaker = currentSpeaker }
    }
    mutating func beginInterruption() { interrupted = true }
    mutating func takeRestore(currentSpeaker: Bool?) -> Bool? {
        guard interrupted else { return nil }
        interrupted = false
        let restore = currentSpeaker == nil ? nil : lastSpeaker
        lastSpeaker = restore ?? currentSpeaker
        restoring = restore != nil
        return restore
    }
    mutating func finishRestoration(currentSpeaker: Bool?, preservingIntent: Bool = false) {
        guard restoring else { return }
        restoring = false
        if !preservingIntent { lastSpeaker = currentSpeaker }
    }
    mutating func cancelForUserSelection(currentSpeaker: Bool?) {
        interrupted = false; restoring = false
        lastSpeaker = currentSpeaker
    }
}

/// Observe intent before the system route chooser opens, leaving native touch handling untouched.
final class AudioRouteInteractionObserver: UIGestureRecognizer {
    private let onInteraction: () -> Void

    init(onInteraction: @escaping () -> Void) {
        self.onInteraction = onInteraction
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onInteraction()
        state = .failed
    }
}
