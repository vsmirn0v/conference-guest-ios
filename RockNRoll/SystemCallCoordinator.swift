import AVFoundation
import CallKit
import Foundation
import OSLog

/// Coordinates live-meeting audio and optional system call controls.
final class SystemCallCoordinator: NSObject, CXProviderDelegate, CXCallObserverDelegate {
    static let controlsPreferenceKey = "SystemCallControlsEnabled"
    var onActivated: (() -> Void)?
    var onAudioYield: (() -> Void)?
    var onDeactivated: (() -> Void)?
    /// True when the user or app deliberately ended the system call.
    var onEnded: ((Bool) -> Void)?
    var onMuteChanged: ((Bool) -> Void)?
    var onHoldChanged: ((Bool) -> Void)?
    var onCallStateChanged: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    struct ObservedCall {
        let id: UUID
        var connected: Bool
        var held: Bool
        var ended: Bool = false
    }

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "RockNRoll", category: "SystemCall")
    private lazy var provider = CXProvider(configuration: Self.providerConfiguration())

    static func providerConfiguration() -> CXProviderConfiguration {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.includesCallsInRecents = false
        configuration.supportedHandleTypes = [.generic]
        configuration.maximumCallsPerCallGroup = 1
        // Retain CallKit's standard allowance for separate active/held calls.
        // The app's callID guard still permits only one meeting of its own.
        configuration.maximumCallGroups = 2
        return configuration
    }
    private lazy var controller = CXCallController()
    private var usesSystemCall: Bool
    private let registrationOverride: Bool?
    private var audioInterruptionObserver: NSObjectProtocol?
    private var applicationRecoveryTask: Task<Void, Never>?
    private var applicationRecoveryToken: UUID?
    private var recoveryDeadline: ContinuousClock.Instant?
    private let recoveryWindow: Duration
    private let recoveryInterval: Duration
    private let transactionRequester: ((CXTransaction, @escaping (Error?) -> Void) -> Void)?
    private let callUpdateReporter: ((UUID, CXCallUpdate) -> Void)?
    private let callSnapshot: (() -> [ObservedCall])?
    private let activateAudioSession: (() throws -> Void)?
    private let sessionWorker: AudioSessionWorker
    private let applicationMute: ApplicationMicrophoneMute?
    private var activationLease: AudioSessionLease?
    private var servicesAvailable = true
    private var ending = false
    private(set) var callID: UUID?
    private var isConnected = false
    private var isMuted = true
    private var isHeld = false
    /// A pre-hold observer snapshot is not proof that iOS released our audio.
    private struct AudioYield {
        var observedHold = false
        var observedCompetitor = false
        var releasedBySystem = false
        var activationAttempted = false
    }
    private var audioYield: AudioYield?
    private var resumeActionID: UUID?
    private var isAudioSessionActive = false
    private(set) var transferHolding = false
    private var transferHoldCompletion: ((Error?) -> Void)?
    private var transferHoldGeneration = UUID()
    private var transferHoldActionID: UUID?
    private var transferSessionLease: AudioSessionLease?

    #if DEBUG
    var diagnosticState: [String: Any] {
        let calls = observedCalls.filter { !$0.ended }
        let owned = calls.first { $0.id == callID }
        return ["systemCallRegistered": usesSystemCall,
                "systemReportedConnected": isConnected,
                "systemObservedConnected": owned?.connected ?? false,
                "systemObservedHeld": owned?.held ?? false,
                "systemLiveCalls": calls.count,
                "systemOtherCalls": calls.filter { $0.id != callID }.count]
    }
    #endif

    var canRestoreAudio: Bool {
        guard let callID, !ending, servicesAvailable, isAudioSessionActive, !isHeld, !transferHolding else { return false }
        return !observedCalls.contains { $0.id == callID ? ($0.held || $0.ended) : !$0.ended }
    }

    /// CallKit delegates update these flags before the engine's queued callbacks.
    /// Consult them when a transport-end event races the hold/deactivation callback.
    var isAwaitingAudioRecovery: Bool {
        guard let callID, isConnected else { return false }
        return isHeld || !isAudioSessionActive ||
            observedCalls.contains { $0.id == callID ? ($0.held && !$0.ended) : !$0.ended }
    }

    init(transactionRequester: ((CXTransaction, @escaping (Error?) -> Void) -> Void)? = nil,
         callUpdateReporter: ((UUID, CXCallUpdate) -> Void)? = nil,
         callSnapshot: (() -> [ObservedCall])? = nil,
         systemCallRegistration: Bool? = nil,
         activateAudioSession: (() throws -> Void)? = nil,
         applicationMute: ApplicationMicrophoneMute? = nil,
         sessionWorker: AudioSessionWorker = .shared,
         recoveryWindow: Duration = .seconds(12), recoveryInterval: Duration = .milliseconds(500)) {
        self.transactionRequester = transactionRequester
        self.callUpdateReporter = callUpdateReporter
        self.callSnapshot = callSnapshot
        self.activateAudioSession = activateAudioSession
        self.sessionWorker = sessionWorker
        self.applicationMute = applicationMute ?? (transactionRequester == nil && callSnapshot == nil && activateAudioSession == nil ? ApplicationMicrophoneMute.shared : nil)
        self.recoveryWindow = recoveryWindow; self.recoveryInterval = recoveryInterval
        registrationOverride = systemCallRegistration
        var register = systemCallRegistration ?? (transactionRequester != nil ||
            (!ProcessInfo.processInfo.isiOSAppOnMac && UserDefaults.standard.bool(forKey: Self.controlsPreferenceKey)))
        #if DEBUG
        if systemCallRegistration == nil && transactionRequester == nil,
           ProcessInfo.processInfo.environment["CONFERENCE_TEST_APP_AUDIO_SESSION"] == "1" { register = false }
        #endif
        usesSystemCall = register
        super.init()
        if transactionRequester == nil { controller.callObserver.setDelegate(self, queue: .main) }
        audioInterruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
                let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                self?.audioSessionInterrupted(type == .began)
            }
    }

    deinit {
        activationLease?.invalidate(); transferSessionLease?.invalidate()
        applicationRecoveryTask?.cancel()
        if let audioInterruptionObserver { NotificationCenter.default.removeObserver(audioInterruptionObserver) }
    }

    /// Standalone AVAudioSession ownership still yields to genuine system calls.
    /// A joined live meeting resumes after an actual interruption-ended event,
    /// even without the media-player `shouldResume` hint. Current competitors
    /// and successful session activation remain authoritative.
    func audioSessionInterrupted(_ interrupted: Bool) {
        guard !usesSystemCall, callID != nil else { return }
        if interrupted {
            cancelApplicationAudioRecovery()
            let wasActive = isAudioSessionActive
            isAudioSessionActive = false
            beginAudioYield()
            if !isHeld { isHeld = true; onHoldChanged?(true) }
            if wasActive { onDeactivated?() }
        } else {
            audioYield?.releasedBySystem = true
            resumeIfPossible()
        }
    }

    private func request(_ transaction: CXTransaction, completion: @escaping (Error?) -> Void) {
        if let transactionRequester { transactionRequester(transaction, completion) }
        else { controller.request(transaction, completion: completion) }
    }

    private func reportCapabilities(for id: UUID, using source: CXProvider? = nil) {
        // Handling CXSetHeldCallAction is not a declaration of hold support.
        // Advertise it explicitly so another system call can hold this meeting.
        let update = CXCallUpdate()
        update.supportsHolding = true
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        if let callUpdateReporter { callUpdateReporter(id, update) }
        else if transactionRequester == nil { (source ?? provider).reportCall(with: id, updated: update) }
    }

    func start() {
        guard callID == nil else { return }
        usesSystemCall = registrationOverride ?? (transactionRequester != nil ||
            (!ProcessInfo.processInfo.isiOSAppOnMac && UserDefaults.standard.bool(forKey: Self.controlsPreferenceKey)))
        #if DEBUG
        if registrationOverride == nil && transactionRequester == nil,
           ProcessInfo.processInfo.environment["CONFERENCE_TEST_APP_AUDIO_SESSION"] == "1" { usesSystemCall = false }
        #endif
        if usesSystemCall && transactionRequester == nil { provider.setDelegate(self, queue: .main) }
        cancelApplicationAudioRecovery()
        finishPendingTransferHold()
        let id = UUID()
        callID = id
        isConnected = false
        isMuted = true
        isHeld = false
        audioYield = nil
        resumeActionID = nil
        isAudioSessionActive = false
        servicesAvailable = true; ending = false
        transferHolding = false
        if !usesSystemCall {
            applicationMute?.begin(owner: id, muted: isMuted) { [weak self] muted in
                guard let self, self.callID == id, !self.ending, self.isConnected, self.canRestoreAudio else { return false }
                self.isMuted = muted
                self.onMuteChanged?(muted)
                return true
            }
            // Application-owned sessions use the same competitor/release guards,
            // without registering an internet call with the system Phone UI.
            #if DEBUG
            print("Application meeting audio: activating")
            #endif
            do {
                if observedCalls.contains(where: { !$0.ended }) {
                    beginAudioYield()
                    onDeactivated?()
                    return
                }
                if let activateAudioSession {
                    // Deterministic ownership tests inject a synchronous grant.
                    try activateAudioSession()
                    applicationMute?.setMuted(isMuted, owner: id)
                    isAudioSessionActive = true; onActivated?()
                } else {
                    enqueueActivation(id: id, initial: true)
                }
            } catch {
                applicationMute?.end(owner: id)
                callID = nil
                onFailure?(error)
            }
            return
        }
        #if DEBUG
        print("System call: requesting start")
        #endif
        let handle = CXHandle(type: .generic, value: L("Jam"))
        let action = CXStartCallAction(call: id, handle: handle)
        action.isVideo = true
        request(CXTransaction(action: action)) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                guard self?.callID == id else { return }
                #if DEBUG
                print("System call: request failed: \(error.localizedDescription)")
                #endif
                self?.callID = nil
                self?.onFailure?(error)
            }
        }
    }

    func markConnected() {
        guard let callID, !isConnected else { return }
        isConnected = true
        guard usesSystemCall else { applicationMute?.setMuted(isMuted, owner: callID); return }
        reportCapabilities(for: callID)
        if transactionRequester == nil { provider.reportOutgoingCall(with: callID, connectedAt: nil) }
        log.notice("CallKit meeting connected; hold supported")
        setMuted(isMuted, force: true)
    }

    func setMuted(_ muted: Bool) {
        setMuted(muted, force: false)
    }

    private func setMuted(_ muted: Bool, force: Bool) {
        guard let callID else { return }
        let changed = isMuted != muted
        isMuted = muted
        guard usesSystemCall else { applicationMute?.setMuted(muted, owner: callID); return }
        guard isConnected, changed || force else { return }
        request(CXTransaction(action: CXSetMutedCallAction(call: callID, muted: muted))) { error in
            guard let error else { return }
            #if DEBUG
            print("System call: mute update failed: \(error.localizedDescription)")
            #endif
        }
    }

    func end() {
        ending = true
        cancelActivation(); cancelApplicationAudioRecovery()
        finishPendingTransferHold()
        guard let callID else { return }
        if !usesSystemCall {
            markEnded(reason: .remoteEnded)
            onEnded?(true)
            return
        }
        request(CXTransaction(action: CXEndCallAction(call: callID))) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                #if DEBUG
                print("System call: end failed: \(error.localizedDescription)")
                #endif
                guard self?.callID == callID else { return }
                self?.markEnded(reason: .failed)
                self?.onEnded?(true)
            }
        }
    }

    func markEnded(reason: CXCallEndedReason) {
        guard let callID else { return }
        applicationMute?.end(owner: callID)
        cancelActivation()
        cancelApplicationAudioRecovery()
        if !usesSystemCall {
            sessionWorker.deactivate()
        }
        self.callID = nil
        isConnected = false
        isHeld = false
        audioYield = nil
        resumeActionID = nil
        isAudioSessionActive = false
        transferHolding = false
        finishPendingTransferHold()
        if usesSystemCall && transactionRequester == nil { provider.reportCall(with: callID, endedAt: nil, reason: reason) }
    }

    func providerDidReset(_ provider: CXProvider) {
        guard usesSystemCall else { return }
        cancelActivation()
        finishPendingTransferHold()
        #if DEBUG
        print("System call: provider reset")
        #endif
        callID = nil
        isConnected = false
        isHeld = false
        audioYield = nil
        resumeActionID = nil
        isAudioSessionActive = false
        onEnded?(false)
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        #if DEBUG
        print("System call: start action")
        #endif
        guard callID == action.callUUID else {
            action.fail()
            return
        }
        reportCapabilities(for: action.callUUID, using: provider)
        if transactionRequester == nil { provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil) }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        guard usesSystemCall, callID != nil, !ending else { return }
        cancelActivation()
        log.notice("CallKit audio activated")
        isAudioSessionActive = true
        audioYield = nil
        onActivated?()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        #if DEBUG
        print("System call: end action")
        #endif
        guard callID == action.callUUID else {
            action.fail()
            return
        }
        cancelActivation()
        finishPendingTransferHold()
        callID = nil
        isConnected = false
        isAudioSessionActive = false
        audioYield = nil
        action.fulfill()
        onEnded?(true)
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard callID == action.callUUID else {
            action.fail()
            return
        }
        isMuted = action.isMuted
        onMuteChanged?(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        guard callID == action.callUUID else {
            action.fail()
            return
        }
        log.notice("CallKit hold requested: \(action.isOnHold, privacy: .public)")
        isHeld = action.isOnHold
        resumeActionID = nil
        if isHeld {
            beginAudioYield()
        } else {
            audioYield?.releasedBySystem = true
        }
        onHoldChanged?(isHeld)
        if transferHoldActionID == action.uuid {
            let transferCompletion = transferHoldCompletion
            transferHoldCompletion = nil; transferHoldActionID = nil
            DispatchQueue.main.async { transferCompletion?(nil) }
        }
        action.fulfill()
        resumeIfPossible()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        guard usesSystemCall, callID != nil else { return }
        log.notice("CallKit audio deactivated")
        isAudioSessionActive = false
        beginAudioYield()
        onDeactivated?()
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        observedCallChanged(ObservedCall(id: call.uuid, connected: call.hasConnected,
                                        held: call.isOnHold, ended: call.hasEnded))
    }

    func observedCallChanged(_ call: ObservedCall) {
        guard let callID else { return }
        if observedCalls.contains(where: { $0.id != callID && !$0.ended }) { cancelActivation() }
        log.notice("Call state: meeting=\(call.id == callID, privacy: .public), connected=\(call.connected, privacy: .public), held=\(call.held, privacy: .public), ended=\(call.ended, privacy: .public)")
        if !usesSystemCall, observedCalls.contains(where: { $0.id != callID && !$0.ended }) {
            audioSessionInterrupted(true)
        }
        resumeIfPossible()
        onCallStateChanged?()
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        // No contact, meeting URL, call UUID or media is written to this log.
        log.error("CallKit action timed out: \(String(describing: type(of: action)), privacy: .public)")
        if action.uuid == resumeActionID {
            resumeActionID = nil
            onCallStateChanged?()
        }
    }

    func resumeIfPossible() {
        guard !ending else { return }
        if !usesSystemCall {
            guard !isAudioSessionActive, audioYield != nil else { return }
            do { _ = try reactivateAudioIfPossible() }
            catch {
                log.notice("Application audio recovery deferred")
                retryApplicationAudioRecovery()
            }
            return
        }
        guard usesSystemCall, !transferHolding else { return }
        let calls = observedCalls
        observeYield(in: calls)
        // Foreground entry and an absent competitor can both precede its arrival.
        // Only completion of a competitor seen during this hold warrants unhold.
        guard let callID, isHeld, audioYield?.observedCompetitor == true,
              !calls.contains(where: { $0.id != callID && !$0.ended }),
              resumeActionID == nil else { return }
        let action = CXSetHeldCallAction(call: callID, onHold: false)
        resumeActionID = action.uuid
        log.notice("Requesting meeting unhold after competing call completed")
        #if DEBUG
        print("System call: requesting meeting resume")
        #endif
        request(CXTransaction(action: action)) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                guard self?.callID == callID, self?.resumeActionID == action.uuid else { return }
                self?.resumeActionID = nil
                #if DEBUG
                print("System call: resume failed: \(error.localizedDescription)")
                #endif
            }
        }
    }

    /// A missing didActivate callback must not permanently strand an established
    /// meeting. Current CallKit ownership and successful AVAudioSession activation
    /// are both required; no competitor or explicit transfer hold may be overridden.
    @discardableResult
    func reactivateAudioIfPossible() throws -> Bool {
        guard let callID, !ending, servicesAvailable, isConnected || !usesSystemCall, !transferHolding else { return false }
        if usesSystemCall {
            let calls = observedCalls
            observeYield(in: calls)
            guard calls.contains(where: { $0.id == callID && $0.connected && !$0.held && !$0.ended }),
                  !calls.contains(where: { $0.id != callID && !$0.ended }) else { return false }
            if let audioYield {
                guard audioYield.releasedBySystem || audioYield.observedHold || audioYield.observedCompetitor else {
                    return false
                }
            }
        } else {
            let calls = observedCalls
            observeYield(in: calls)
            guard !calls.contains(where: { $0.id != callID && !$0.ended }) else { return false }
            if isHeld && audioYield == nil { return false }
            if let audioYield, !audioYield.releasedBySystem && !audioYield.observedCompetitor { return false }
            if isAudioSessionActive && !isHeld && audioYield == nil { return true }
        }
        audioYield?.activationAttempted = true
        guard let activateAudioSession else {
            enqueueActivation(id: callID, initial: false)
            return false // onActivated fires only after the worker grants audio.
        }
        try activateAudioSession()
        if !usesSystemCall { applicationMute?.setMuted(isMuted, owner: callID) }
        // Reconcile a missed unhold delegate callback against the current call,
        // only after the system actually grants activation.
        if isHeld {
            isHeld = false; resumeActionID = nil
            onHoldChanged?(false)
        }
        isAudioSessionActive = true
        audioYield = nil
        cancelApplicationAudioRecovery()
        log.notice("Meeting audio reactivated after verified system release")
        onActivated?()
        return true
    }

    /// Service resets retire the current grant even when no interruption arrives.
    /// The engine calls the ready half after restoring its category on the worker.
    func audioServicesChanged(_ available: Bool) {
        guard callID != nil else { return }
        servicesAvailable = available
        if !available {
            cancelActivation(); isAudioSessionActive = false
            beginAudioYield(); onDeactivated?()
        } else {
            audioYield?.releasedBySystem = true
            do { _ = try reactivateAudioIfPossible() }
            catch { retryApplicationAudioRecovery() }
        }
    }

    private func cancelActivation() { activationLease?.invalidate(); activationLease = nil }

    private func enqueueActivation(id: UUID, initial: Bool) {
        guard !ending, activationLease == nil else { return }
        let lease = AudioSessionLease(); activationLease = lease
        sessionWorker.activate(lease: lease) { [weak self] result in
            Task { @MainActor in
                guard let self, self.callID == id, self.activationLease === lease, lease.isActive else { return }
                self.activationLease = nil
                // A competitor can arrive during the native session call. Never
                // publish a grant until ownership has been checked again.
                guard !self.ending, self.servicesAvailable, !self.transferHolding,
                      !self.usesSystemCall || self.observedCalls.contains(where: { $0.id == id && $0.connected && !$0.held && !$0.ended }),
                      !self.observedCalls.contains(where: { $0.id == id ? ($0.held || $0.ended) : !$0.ended }),
                      initial || !self.isHeld || self.audioYield?.releasedBySystem == true || self.audioYield?.observedCompetitor == true else { return }
                switch result {
                case .success:
                    if !self.usesSystemCall { self.applicationMute?.setMuted(self.isMuted, owner: id) }
                    if self.isHeld { self.isHeld = false; self.resumeActionID = nil; self.onHoldChanged?(false) }
                    self.isAudioSessionActive = true; self.audioYield = nil
                    self.cancelApplicationAudioRecovery(); self.onActivated?()
                case .failure(let error):
                    if error is CancellationError { return }
                    if initial { self.applicationMute?.end(owner: id); self.callID = nil; self.onFailure?(error) }
                    else { self.retryApplicationAudioRecovery() }
                }
            }
        }
    }

    private func retryApplicationAudioRecovery() {
        guard applicationRecoveryTask == nil, let id = callID,
              !usesSystemCall || audioYield?.releasedBySystem == true else { return }
        let deadline = recoveryDeadline ?? ContinuousClock.now.advanced(by: recoveryWindow)
        recoveryDeadline = deadline
        guard ContinuousClock.now < deadline else { return }
        let token = UUID(); applicationRecoveryToken = token
        applicationRecoveryTask = Task { @MainActor [weak self] in
            defer {
                if self?.applicationRecoveryToken == token {
                    self?.applicationRecoveryTask = nil; self?.applicationRecoveryToken = nil
                }
            }
            while ContinuousClock.now < deadline {
                guard let interval = self?.recoveryInterval else { return }
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, self.callID == id, !self.ending, ContinuousClock.now < deadline else { return }
                do {
                    if try self.reactivateAudioIfPossible() { return }
                    if self.audioYield == nil { return }
                }
                catch { /* The competing session may still be finishing teardown. */ }
            }
        }
    }

    private func cancelApplicationAudioRecovery() {
        applicationRecoveryToken = nil; recoveryDeadline = nil
        applicationRecoveryTask?.cancel(); applicationRecoveryTask = nil
    }

    #if DEBUG
    func requestHoldForTesting(_ held: Bool) {
        guard let callID else { return }
        request(CXTransaction(action: CXSetHeldCallAction(call: callID, onHold: held))) { error in
            if let error { print("Test hold request failed: \(error.localizedDescription)") }
        }
    }
    #endif

    /// Use the established conference hold path instead of competing with the
    /// provider's WebRTC audio session. The Mac runtime owns its AVAudioSession.
    @MainActor func setTransferHeld(_ held: Bool) async throws {
        guard let id = callID, transferHoldCompletion == nil else { throw NSError(domain: "JamTransfer", code: 1) }
        transferHolding = held
        let generation = UUID(); transferHoldGeneration = generation
        transferSessionLease?.invalidate()
        let sessionLease = AudioSessionLease(); transferSessionLease = sessionLease
        if !usesSystemCall {
            if held {
                isHeld = true
                beginAudioYield()
                onHoldChanged?(true)
                cancelApplicationAudioRecovery()
                try await sessionWorker.deactivate(lease: sessionLease)
                guard callID == id, transferHoldGeneration == generation else { throw CancellationError() }
                isAudioSessionActive = false
                onDeactivated?()
            } else {
                audioYield?.releasedBySystem = true
                if try reactivateAudioIfPossible() == false, let pending = activationLease {
                    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                    while activationLease === pending, !canRestoreAudio, ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(20))
                        guard callID == id, transferHoldGeneration == generation else { throw CancellationError() }
                    }
                }
                guard callID == id, transferHoldGeneration == generation else { throw CancellationError() }
                guard canRestoreAudio else { throw NSError(domain: "JamAudioOwnership", code: 2) }
            }
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
            return
        }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let action = CXSetHeldCallAction(call: id, onHold: held)
            transferHoldActionID = action.uuid
            transferHoldCompletion = { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            }
            request(CXTransaction(action: action)) { [weak self] error in
                guard let error else { return }
                DispatchQueue.main.async {
                    guard self?.callID == id, self?.transferHoldGeneration == generation else { return }
                    let completion = self?.transferHoldCompletion
                    self?.transferHoldCompletion = nil; self?.transferHoldActionID = nil
                    completion?(error)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard self?.callID == id, self?.transferHoldGeneration == generation,
                      let completion = self?.transferHoldCompletion else { return }
                self?.transferHoldCompletion = nil; self?.transferHoldActionID = nil
                completion(NSError(domain: "JamTransfer", code: 3))
            }
        }
    }
    private func finishPendingTransferHold() {
        transferSessionLease?.invalidate(); transferSessionLease = nil
        transferHoldCompletion?(NSError(domain: "JamTransfer", code: 2))
        transferHoldCompletion = nil
        transferHoldActionID = nil
        transferHolding = false; transferHoldGeneration = UUID()
    }

    private func beginAudioYield() {
        onAudioYield?()
        cancelActivation()
        // Preserve evidence in either hold/deactivation callback order. A release
        // is a boundary, including an inferred release whose activation failed.
        // The next interruption cannot reuse that attempt's permission.
        if audioYield == nil || audioYield?.releasedBySystem == true || audioYield?.activationAttempted == true {
            cancelApplicationAudioRecovery()
            audioYield = AudioYield()
        }
        observeYield(in: observedCalls)
    }

    private func observeYield(in calls: [ObservedCall]) {
        guard let callID, audioYield != nil else { return }
        // Read the current snapshot: a delayed callback from an unrelated ended
        // call cannot authorize this episode's recovery.
        if calls.contains(where: { $0.id == callID && $0.held && !$0.ended }) {
            audioYield?.observedHold = true
        }
        if calls.contains(where: { $0.id != callID && !$0.ended }) {
            audioYield?.observedCompetitor = true
        }
    }

    private var observedCalls: [ObservedCall] {
        if let callSnapshot { return callSnapshot() }
        return controller.callObserver.calls.map {
            ObservedCall(id: $0.uuid, connected: $0.hasConnected, held: $0.isOnHold, ended: $0.hasEnded)
        }
    }
}
