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
    private var lease = AudioSessionLease()
    private var observingSession = false
    private var mixingTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var startupReady: (@MainActor () async throws -> Void)?
    private var startupFailure: (@MainActor (Error) -> Void)?
    private var mixingRevision = 0
    private var configurationLease: AudioSessionLease? = AudioSessionLease()
    private var routeLease: AudioSessionLease?
    private var observers: [NSObjectProtocol] = []
    private var audioWarning: String?
    private var cameraWarning: String?
    private var macRouteSubscription: AnyCancellable?

    var outputName: String {
        if ProcessInfo.processInfo.isiOSAppOnMac, let name = MacAudioDevices.shared.snapshot.outputName { return name }
        guard let output = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return L("Audio output") }
        switch output.portType {
        case .builtInSpeaker: return L("Speaker")
        case .builtInReceiver: return L("iPhone receiver")
        default: return output.portName
        }
    }

    init(worker: AudioSessionWorker = .shared) {
        self.worker = worker
        if ProcessInfo.processInfo.isiOSAppOnMac {
            macRouteSubscription = MacAudioDevices.shared.$snapshot.dropFirst()
                .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.onRouteChanged?() }
        }
        let center = NotificationCenter.default
        for name in [AVAudioSession.interruptionNotification,
                     AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereLostNotification,
                     AVAudioSession.mediaServicesWereResetNotification,
                     AVCaptureSession.wasInterruptedNotification,
                     AVCaptureSession.interruptionEndedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.handle(note) }
            })
        }
    }

    deinit {
        lease.invalidate(); configurationLease?.invalidate(); routeLease?.invalidate()
        mixingTask?.cancel(); resetTask?.cancel(); startupTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func beginSession() {
        endSession()
        lease = AudioSessionLease(); configurationLease = AudioSessionLease(); observingSession = true
    }
    func endSession() {
        observingSession = false; lease.invalidate()
        mixingTask?.cancel(); mixingTask = nil
        resetTask?.cancel(); resetTask = nil
        startupTask?.cancel(); startupTask = nil
        startupReady = nil; startupFailure = nil
        suspendConfiguration()
    }

    /// Hold retires optional category/route work without retiring the meeting.
    func suspendConfiguration() {
        configurationLease?.invalidate(); configurationLease = nil
        routeLease?.invalidate(); routeLease = nil
        mixingTask?.cancel(); mixingTask = nil
    }

    func start(ready: @escaping @MainActor () async throws -> Void,
               failure: @escaping @MainActor (Error) -> Void) {
        beginSession()
        startupReady = ready; startupFailure = failure
        let expected = lease
        startupTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.prepareForJoin()
                guard self.lease === expected, expected.isActive else { return }
                try await ready()
                if self.lease === expected { self.startupReady = nil; self.startupFailure = nil }
            } catch is CancellationError { }
            catch { if self.lease === expected, expected.isActive { failure(error) } }
            if self.lease === expected { self.startupTask = nil }
        }
    }

    /// The provider may reconfigure the shared session later; real-device validation is required.
    func prepareForJoin() async throws {
        let expected = lease
        try await worker.perform(lease: expected) {
            let session = AVAudioSession.sharedInstance()
            let options: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowBluetoothHFP]
            if session.category != .playAndRecord || session.mode != .videoChat || session.categoryOptions != options {
                try session.setCategory(.playAndRecord, mode: .videoChat, options: options)
            }
        }
        guard lease === expected, expected.isActive else { throw CancellationError() }
        observingSession = true
        // CallKit activates the session before the SDK starts media.
        audioWarning = nil
        cameraWarning = nil
        publishStatus()
    }

    /// Video-chat mode implies a speaker default. Clearing a port override alone
    /// cannot select the receiver, so choose the matching communication mode too.
    func selectBuiltInOutput(speaker: Bool) async throws {
        guard let configuration = configurationLease, configuration.isActive else { throw CancellationError() }
        let expected = lease
        routeLease?.invalidate()
        let request = AudioSessionLease(); routeLease = request
        try await worker.perform(lease: request) {
            try expected.check(); try configuration.check()
            let session = AVAudioSession.sharedInstance()
            var options = session.categoryOptions
            if !speaker { options.remove(.defaultToSpeaker) }
            let mode: AVAudioSession.Mode = [.voiceChat, .videoChat].contains(session.mode)
                ? (speaker ? .videoChat : .voiceChat) : session.mode
            if session.mode != mode || session.categoryOptions != options {
                try session.setCategory(session.category, mode: mode, options: options)
            }
            try expected.check(); try request.check(); try configuration.check()
            if let input = session.availableInputs?.first(where: { $0.portType == .builtInMic }), session.preferredInput != input {
                try session.setPreferredInput(input)
            }
            try expected.check(); try request.check(); try configuration.check()
            try session.overrideOutputAudioPort(speaker ? .speaker : .none)
        }
        guard lease === expected, expected.isActive, routeLease === request else { throw CancellationError() }
        onRouteChanged?()
    }

    /// The SDK changes the shared session after join; restore coexistence without
    /// replacing its selected voice-chat mode or route options.
    func ensureMixing() {
        guard lease.isActive, let configuration = configurationLease, configuration.isActive else { return }
        mixingRevision &+= 1
        guard mixingTask == nil else { return }
        let expected = lease
        mixingTask = Task { [weak self, worker] in
            guard let self else { return }
            defer { if self.lease === expected, self.configurationLease === configuration { self.mixingTask = nil } }
            while self.lease === expected, expected.isActive, configuration.isActive, !Task.isCancelled {
                let revision = self.mixingRevision
                do { try await worker.perform(lease: configuration) { try expected.check(); try Self.restoreMixing() } }
                catch is CancellationError { return }
                catch {
                    guard self.lease === expected, expected.isActive else { return }
                    self.audioWarning = L("Cannot mix jam audio with other apps"); self.publishStatus(); return
                }
                if self.mixingRevision == revision { return }
            }
        }
    }

    private nonisolated static func restoreMixing() throws {
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playAndRecord, !session.categoryOptions.contains(.mixWithOthers) else { return }
        try session.setCategory(session.category, mode: session.mode, options: session.categoryOptions.union(.mixWithOthers))
    }

    /// A new CallKit activation supersedes an earlier interruption warning.
    func callAudioDidActivate() {
        guard observingSession, lease.isActive else { return }
        if configurationLease == nil { configurationLease = AudioSessionLease() }
        audioWarning = nil
        ensureMixing()
        logRoute()
        publishStatus()
    }

    /// iOS can deliver an interruption-began notification after CallKit has
    /// returned an active call session, without a matching ended notification.
    /// Reactivate only once the call owner confirms there is no competing call.
    func reactivateAfterInterruption() async throws {
        let expected = lease
        try await worker.perform(lease: expected) {
            try AVAudioSession.sharedInstance().setActive(true)
            try expected.check(); try Self.restoreMixing()
        }
        guard lease === expected, expected.isActive else { throw CancellationError() }
        audioWarning = nil
        logRoute()
        publishStatus()
    }

    private func handle(_ notification: Notification) {
        guard observingSession else { return }
        #if DEBUG
        let session = AVAudioSession.sharedInstance()
        print("Audio event: \(notification.name.rawValue), category=\(session.category.rawValue), mode=\(session.mode.rawValue), options=\(session.categoryOptions.rawValue), appState=\(UIApplication.shared.applicationState.rawValue)")
        #endif
        switch notification.name {
        case AVAudioSession.interruptionNotification:
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            if type == .began {
                suspendConfiguration()
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
            lease.invalidate(); suspendConfiguration()
            audioWarning = L("Audio service unavailable")
            onServicesChanged?(false)
            onInterruptionChanged?(true)
        case AVAudioSession.mediaServicesWereResetNotification:
            recoverServices()
        case AVCaptureSession.wasInterruptedNotification:
            cameraWarning = L("Camera paused by iOS")
        case AVCaptureSession.interruptionEndedNotification:
            cameraWarning = nil
        case AVAudioSession.routeChangeNotification:
            // The provider's route picker and the current system route remain authoritative.
            logRoute()
            ensureMixing()
            onRouteChanged?()
        default:
            break
        }
        publishStatus()
    }

    private func recoverServices() {
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
            do {
                try await self.prepareForJoin()
                guard self.lease === expected, expected.isActive else { return }
                if let ready = self.startupReady {
                    try await ready()
                    guard self.lease === expected, expected.isActive else { return }
                    self.startupReady = nil; self.startupFailure = nil
                }
                self.onServicesChanged?(true)
                self.onInterruptionChanged?(false)
            } catch is CancellationError { }
            catch {
                guard self.lease === expected, expected.isActive else { return }
                self.audioWarning = L("Audio could not resume: %@", error.localizedDescription); self.publishStatus()
                self.startupFailure?(error)
            }
            if self.lease === expected { self.resetTask = nil }
        }
    }

    private func publishStatus() {
        onStatus?(audioWarning ?? cameraWarning)
    }

    private func logRoute() {
        #if DEBUG
        let route = AVAudioSession.sharedInstance().currentRoute
        let inputs = route.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outputs = route.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        print("Audio route types: input=[\(inputs)] output=[\(outputs)]")
        #endif
    }
}
