import AVFoundation
import CallKit
import Foundation
import OSLog

/// Reports only a real, user-requested conference to the system call UI.
final class SystemCallCoordinator: NSObject, CXProviderDelegate, CXCallObserverDelegate {
    var onActivated: (() -> Void)?
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
    private let usesSystemCall: Bool
    private let transactionRequester: ((CXTransaction, @escaping (Error?) -> Void) -> Void)?
    private let callUpdateReporter: ((UUID, CXCallUpdate) -> Void)?
    private let callSnapshot: (() -> [ObservedCall])?
    private let activateAudioSession: () throws -> Void
    private(set) var callID: UUID?
    private var isConnected = false
    private var isMuted = true
    private var isHeld = false
    private var shouldResumeAfterHold = false
    private var resumeActionID: UUID?
    private var isAudioSessionActive = false
    private(set) var transferHolding = false
    private var transferHoldCompletion: ((Error?) -> Void)?
    private var transferHoldGeneration = UUID()
    private var transferHoldActionID: UUID?

    var canRestoreAudio: Bool {
        guard let callID, isAudioSessionActive, !isHeld, !transferHolding else { return false }
        guard usesSystemCall else { return true }
        return !observedCalls.contains { $0.id == callID ? ($0.held || $0.ended) : !$0.ended }
    }

    init(transactionRequester: ((CXTransaction, @escaping (Error?) -> Void) -> Void)? = nil,
         callUpdateReporter: ((UUID, CXCallUpdate) -> Void)? = nil,
         callSnapshot: (() -> [ObservedCall])? = nil,
         activateAudioSession: @escaping () throws -> Void = { try AVAudioSession.sharedInstance().setActive(true) }) {
        self.transactionRequester = transactionRequester
        self.callUpdateReporter = callUpdateReporter
        self.callSnapshot = callSnapshot
        self.activateAudioSession = activateAudioSession
        usesSystemCall = transactionRequester != nil || !ProcessInfo.processInfo.isiOSAppOnMac
        super.init()
        if usesSystemCall && transactionRequester == nil {
            provider.setDelegate(self, queue: .main)
            controller.callObserver.setDelegate(self, queue: .main)
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
        finishPendingTransferHold()
        let id = UUID()
        callID = id
        isConnected = false
        isMuted = true
        isHeld = false
        shouldResumeAfterHold = false
        resumeActionID = nil
        isAudioSessionActive = false
        transferHolding = false
        if !usesSystemCall {
            // iOS apps running on Mac don't receive the CallKit audio activation
            // callback reliably; the app owns this session until the jam ends.
            #if DEBUG
            print("Mac meeting audio: activating")
            #endif
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                isAudioSessionActive = true
                onActivated?()
            } catch {
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
        guard usesSystemCall else { return }
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
        guard usesSystemCall else { return }
        guard isConnected, changed || force else { return }
        request(CXTransaction(action: CXSetMutedCallAction(call: callID, muted: muted))) { error in
            guard let error else { return }
            #if DEBUG
            print("System call: mute update failed: \(error.localizedDescription)")
            #endif
        }
    }

    func end() {
        guard let callID else { return }
        if !usesSystemCall {
            finishPendingTransferHold()
            self.callID = nil
            isConnected = false
            isAudioSessionActive = false
            try? AVAudioSession.sharedInstance().setActive(false,
                options: .notifyOthersOnDeactivation)
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
        self.callID = nil
        isConnected = false
        isHeld = false
        shouldResumeAfterHold = false
        resumeActionID = nil
        isAudioSessionActive = false
        transferHolding = false
        finishPendingTransferHold()
        if usesSystemCall && transactionRequester == nil { provider.reportCall(with: callID, endedAt: nil, reason: reason) }
    }

    func providerDidReset(_ provider: CXProvider) {
        guard usesSystemCall else { return }
        finishPendingTransferHold()
        #if DEBUG
        print("System call: provider reset")
        #endif
        callID = nil
        isConnected = false
        isHeld = false
        shouldResumeAfterHold = false
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
        log.notice("CallKit audio activated")
        guard callID != nil else { return }
        isAudioSessionActive = true
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
        finishPendingTransferHold()
        callID = nil
        isConnected = false
        isAudioSessionActive = false
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
            shouldResumeAfterHold = hasAnotherActiveCall
        } else {
            shouldResumeAfterHold = false
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
        log.notice("CallKit audio deactivated")
        guard callID != nil else { return }
        isAudioSessionActive = false
        onDeactivated?()
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        observedCallChanged(ObservedCall(id: call.uuid, connected: call.hasConnected,
                                        held: call.isOnHold, ended: call.hasEnded))
    }

    func observedCallChanged(_ call: ObservedCall) {
        guard let callID else { return }
        // Notifications can be delayed while iOS suspends the app. Attribution
        // depends on overlapping calls, not a three-second delivery window.
        if call.id != callID, !call.ended, isHeld, !transferHolding {
            shouldResumeAfterHold = true
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

    func resumeIfPossible(afterReturningToMeeting: Bool = false) {
        guard usesSystemCall, !transferHolding else { return }
        // Returning to the meeting is also a resume request when iOS omitted
        // the competing call's lifecycle notifications during suspension.
        if isHeld, hasAnotherActiveCall || afterReturningToMeeting { shouldResumeAfterHold = true }
        guard let callID, isHeld, shouldResumeAfterHold,
              !hasAnotherActiveCall, resumeActionID == nil else { return }
        let action = CXSetHeldCallAction(call: callID, onHold: false)
        resumeActionID = action.uuid
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
        guard let callID, isConnected, !transferHolding else { return false }
        if usesSystemCall {
            let calls = observedCalls
            guard calls.contains(where: { $0.id == callID && $0.connected && !$0.held && !$0.ended }),
                  !calls.contains(where: { $0.id != callID && !$0.ended }) else { return false }
        } else if isHeld {
            return false // On Mac, the app owns its AVAudioSession and hold state.
        }
        try activateAudioSession()
        // Reconcile a missed unhold delegate callback against the current call,
        // only after the system actually grants activation.
        if isHeld {
            isHeld = false; shouldResumeAfterHold = false; resumeActionID = nil
            onHoldChanged?(false)
        }
        isAudioSessionActive = true
        onActivated?()
        return true
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
    func setTransferHeld(_ held: Bool) async throws {
        guard let id = callID, transferHoldCompletion == nil else { throw NSError(domain: "JamTransfer", code: 1) }
        transferHolding = held
        let generation = UUID(); transferHoldGeneration = generation
        if !usesSystemCall {
            isHeld = held
            onHoldChanged?(held)
            if held {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                isAudioSessionActive = false
                onDeactivated?()
            } else {
                try AVAudioSession.sharedInstance().setActive(true)
                isAudioSessionActive = true
                onActivated?()
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
        transferHoldCompletion?(NSError(domain: "JamTransfer", code: 2))
        transferHoldCompletion = nil
        transferHoldActionID = nil
        transferHolding = false; transferHoldGeneration = UUID()
    }

    private var hasAnotherActiveCall: Bool {
        guard usesSystemCall else { return false }
        guard let callID else { return false }
        return observedCalls.contains { $0.id != callID && !$0.ended }
    }

    private var observedCalls: [ObservedCall] {
        if let callSnapshot { return callSnapshot() }
        return controller.callObserver.calls.map {
            ObservedCall(id: $0.uuid, connected: $0.hasConnected, held: $0.isOnHold, ended: $0.hasEnded)
        }
    }
}
