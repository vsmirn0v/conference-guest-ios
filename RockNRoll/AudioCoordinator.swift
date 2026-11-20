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
    private var callAudioActive = false
    private let speakerPlayback = IPhoneSpeakerPlaybackProcessor()
    private var proximityRoutingNeeded = true
    private var ownsProximityMonitoring = false
    private var proximityPolicy = ProximityOutputPolicy()
    private var pendingProximityOutput: (speaker: Bool, lease: AudioSessionLease)?
    private var observers: [NSObjectProtocol] = []

    struct Output: Equatable, Sendable {
        let name: String
        let builtInSpeaker: Bool?
    }
    private struct RouteSnapshot: Sendable {
        let output: Output
        let outputPorts: [AVAudioSession.Port]
        let proximityRoute: ProximityOutputPolicy.Route
        let needsMixingRestore: Bool
        let debugSummary: String
    }

    private final class SnapshotBox: @unchecked Sendable {
        var value: RouteSnapshot?
        var changed = false
    }

    private(set) var output = Output(name: L("Audio output"), builtInSpeaker: nil)
    private var proximityRoute = ProximityOutputPolicy.Route.unavailable
    private var routeSnapshotRevision = 0
    private var audioWarning: String?
    private var cameraWarning: String?

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
                     UIDevice.proximityStateDidChangeNotification,
                     UIApplication.didBecomeActiveNotification,
                     AVCaptureSession.wasInterruptedNotification,
                     AVCaptureSession.interruptionEndedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.handle(note) }
            })
        }
    }

    isolated deinit {
        speakerPlayback.setEnabled(false)
        stopProximityMonitoring()
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
        proximityPolicy = ProximityOutputPolicy()
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
        // The phone may have moved while CallKit owned the sensor and output.
        // An automatic receiver choice follows the next live proximity reading.
        if proximityPolicy.returnToSpeaker {
            outputRecovery.cancelForUserSelection(currentSpeaker: currentBuiltInSpeaker)
            return
        }
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
        proximityPolicy.userWillSelectOutput(isNear: UIDevice.current.proximityState)
        cancelProximityOutput()
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
        output.builtInSpeaker
    }

    private func applyRouteSnapshot(_ snapshot: RouteSnapshot) {
        output = snapshot.output
        proximityRoute = snapshot.proximityRoute
        speakerPlayback.setEnabled(callAudioActive && Self.usesIPhoneSpeaker(
            idiom: UIDevice.current.userInterfaceIdiom, outputs: snapshot.outputPorts))
        updateProximityRouting()
    }

    static func usesIPhoneSpeaker(idiom: UIUserInterfaceIdiom, outputs: [AVAudioSession.Port]) -> Bool {
        idiom == .phone && outputs == [.builtInSpeaker]
    }

    func setProximityRoutingNeeded(_ needed: Bool) {
        proximityRoutingNeeded = needed
        updateProximityRouting()
    }

    private func updateProximityRouting() {
        guard callAudioActive, proximityRoutingNeeded, UIDevice.current.userInterfaceIdiom == .phone else {
            stopProximityMonitoring()
            return
        }
        guard proximityRoute == .builtIn, let currentSpeaker = currentBuiltInSpeaker else {
            if proximityRoute == .accessory { proximityPolicy = ProximityOutputPolicy() }
            stopProximityMonitoring()
            return
        }
        let device = UIDevice.current
        if !device.isProximityMonitoringEnabled {
            device.isProximityMonitoringEnabled = true
            ownsProximityMonitoring = device.isProximityMonitoringEnabled
        }
        guard device.isProximityMonitoringEnabled,
              let speaker = proximityPolicy.requestedSpeaker(isNear: device.proximityState,
                  currentSpeaker: currentSpeaker, pendingSpeaker: pendingProximityOutput?.speaker) else { return }

        cancelProximityOutput()
        cancelOutputRestoration()
        outputRecovery.cancelForUserSelection(currentSpeaker: speaker)
        let request = AudioSessionLease()
        pendingProximityOutput = (speaker, request)
        Task { [weak self] in
            guard let self, request.isActive else { return }
            defer {
                if self.pendingProximityOutput?.lease === request { self.pendingProximityOutput = nil }
            }
            do {
                try await self.applyBuiltInOutput(speaker: speaker, preservingExternalRoute: true,
                                                  onlyIfDifferent: true, request: request)
            } catch is CancellationError { }
            catch {
                guard request.isActive else { return }
                self.audioWarning = error.localizedDescription
                self.publishStatus()
            }
        }
    }

    private func stopProximityMonitoring() {
        cancelProximityOutput()
        if ownsProximityMonitoring {
            ownsProximityMonitoring = false
            UIDevice.current.isProximityMonitoringEnabled = false
        }
    }

    private func cancelProximityOutput() {
        pendingProximityOutput?.lease.invalidate()
        pendingProximityOutput = nil
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
                let previousOutput = self.output
                self.applyRouteSnapshot(snapshot)
                #if DEBUG
                print("Audio route types: \(snapshot.debugSummary)")
                #endif
                after?()
                if notify && self.output != previousOutput {
                    self.onRouteChanged?()
                }
            }
        }
    }

    private nonisolated static func inspectRouteSnapshot(_ session: AVAudioSession = AVAudioSession.sharedInstance()) -> RouteSnapshot {
        let route = session.currentRoute
        let outputs = route.outputs
        let inputs = route.inputs
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
        let speaker = builtInSpeaker(route)
        let needsMixing = session.category == .playAndRecord && !session.categoryOptions.contains(.mixWithOthers)
        let summary = "input=[\(inputs.map { $0.portType.rawValue }.joined(separator: ","))] output=[\(outputs.map { $0.portType.rawValue }.joined(separator: ","))]"
        return RouteSnapshot(output: Output(name: outputName, builtInSpeaker: speaker),
                             outputPorts: outputs.map(\.portType),
                             proximityRoute: Self.proximityRoute(route),
                             needsMixingRestore: needsMixing, debugSummary: summary)
    }

    private nonisolated static func builtInSpeaker(_ route: AVAudioSessionRouteDescription) -> Bool? {
        switch route.outputs.first?.portType {
        case .builtInSpeaker: return true
        case .builtInReceiver: return false
        default: return nil
        }
    }

    private nonisolated static func proximityRoute(_ route: AVAudioSessionRouteDescription) -> ProximityOutputPolicy.Route {
        ProximityOutputPolicy.route(inputs: route.inputs.map(\.portType), outputs: route.outputs.map(\.portType))
    }

    /// Hold retires optional category/route work without retiring the meeting.
    func suspendConfiguration() {
        callAudioActive = false
        speakerPlayback.setEnabled(false)
        stopProximityMonitoring()
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

    private func applyBuiltInOutput(speaker: Bool, preservingExternalRoute: Bool = false, onlyIfDifferent: Bool = false,
                                    request: AudioSessionLease = AudioSessionLease()) async throws {
        guard let configuration = configurationLease, configuration.isActive else { throw CancellationError() }
        let expected = lease
        routeLease?.invalidate()
        routeLease = request
        let box = SnapshotBox()
        try await worker.perform(lease: request) {
            try expected.check(); try configuration.check()
            let session = AVAudioSession.sharedInstance()
            let route = session.currentRoute
            let currentSpeaker = Self.builtInSpeaker(route)
            if preservingExternalRoute && (Self.proximityRoute(route) != .builtIn || session.category != .playAndRecord) {
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
            if preservingExternalRoute && Self.proximityRoute(session.currentRoute) != .builtIn {
                box.value = Self.inspectRouteSnapshot(session)
                return
            }
            if !preservingExternalRoute, let input = session.availableInputs?.first(where: { $0.portType == .builtInMic }), session.preferredInput != input {
                try session.setPreferredInput(input)
            }
            try expected.check(); try request.check(); try configuration.check()
            try session.overrideOutputAudioPort(speaker ? .speaker : .none)
            box.changed = true
            box.value = Self.inspectRouteSnapshot(session)
        }
        guard lease === expected, expected.isActive, routeLease === request, request.isActive else { throw CancellationError() }
        let previousOutput = output
        if let snapshot = box.value {
            applyRouteSnapshot(snapshot)
        }
        if box.changed || output != previousOutput {
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
        callAudioActive = true
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
            let previousOutput = output
            applyRouteSnapshot(snapshot)
            #if DEBUG
            print("Audio route types: \(snapshot.debugSummary)")
            #endif
            if output != previousOutput { onRouteChanged?() }
        }
        publishStatus()
    }

    private func handle(_ notification: Notification) {
        guard observingSession else { return }
        switch notification.name {
        case UIDevice.proximityStateDidChangeNotification:
            updateProximityRouting()
            return
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

/// Only an automatic trip to the receiver gets a matching trip back to speaker.
/// A manual receiver choice survives lowering the phone.
struct ProximityOutputPolicy {
    enum Route {
        case unavailable, builtIn, accessory
    }

    private(set) var returnToSpeaker = false
    private var manualChoiceWhileNear = false

    static func route(inputs: [AVAudioSession.Port], outputs: [AVAudioSession.Port]) -> Route {
        guard !outputs.isEmpty else { return .unavailable }
        let builtIn = (outputs == [.builtInSpeaker] || outputs == [.builtInReceiver]) && inputs.allSatisfy { $0 == .builtInMic }
        return builtIn ? .builtIn : .accessory
    }

    mutating func requestedSpeaker(isNear: Bool, currentSpeaker: Bool, pendingSpeaker: Bool? = nil) -> Bool? {
        if isNear {
            guard pendingSpeaker ?? currentSpeaker, !manualChoiceWhileNear else { return nil }
            returnToSpeaker = true
            return false
        }
        manualChoiceWhileNear = false
        guard returnToSpeaker else { return nil }
        if currentSpeaker && pendingSpeaker == nil {
            returnToSpeaker = false
            return nil
        }
        return pendingSpeaker == true ? nil : true
    }

    mutating func userWillSelectOutput(isNear: Bool) {
        returnToSpeaker = false
        manualChoiceWhileNear = isNear
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
